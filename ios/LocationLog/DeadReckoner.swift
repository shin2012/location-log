import Foundation

/// GPS가 끊긴 구간(터널·지하차도 등)을 아이폰 센서(자이로·가속도·나침반)로 추정해 이어 붙임.
/// 웹판 public/track.js Tracker와 같은 규칙. CoreMotion·CoreLocation 없이 숫자만 다룸(리눅스에서도 시험 가능).
///
/// - 평소: GPS 고정점을 받아 기억하고, 진행 방향 가속도 치우침을 학습
/// - 끊김: 마지막 고정점의 속도·진행 방향에서 출발
///   · 진행 방향 = 끊기기 직전 방향 + 그 뒤 수직축 회전량(자이로). 나침반은 긴 끊김에서만 약하게 끌어당김
///   · 속도 = 직전 속도 + 진행 방향 가속도 적분(치우침 제거), 직전 속도로 천천히 복원
///   · 1초마다 추정점 생성
/// - 복귀: 다시 잡힌 GPS와 추정 끝점의 차이를 끊긴 구간 전체에 시간 비례로 나눠 보정
final class DeadReckoner {
    struct Params {
        var lossSec = 3.0           // 이 시간 동안 고정점이 없으면 추정 시작
        var minDrSpeed = 2.5        // m/s 미만에서 끊기면 추정 없이 대기(실내 보행 등)
        var speedTau = 90.0         // s, 추정 속도를 직전 GPS 속도로 되돌리는 시간
        var compassAfter = 120.0    // s, 이보다 긴 끊김에서만 나침반으로 방향 보정
        var compassTau = 120.0      // s
        var compassMaxDiff = 12.0   // ° 이상 어긋나면 나침반 무시(차체·터널 자기 교란)
        var staleSec = 5.0          // 센서 값이 이만큼 안 오면(앱 멈춤) 추정 중단
        var maxGapSec = 600.0       // 이보다 길게 끊기면 더 추정하지 않고 대기
    }

    struct Fix {
        var t: Double       // s (epoch)
        var lat: Double
        var lon: Double
        var alt: Double?
        var acc: Double?
        var spd: Double?    // m/s (기기 값)
        var hdg: Double?    // ° 진북 (기기 값)
    }

    struct Point: Equatable {
        var t: Double
        var lat: Double
        var lon: Double
        var alt: Double?
        var acc: Double
        var spd: Double
        var hdg: Double
    }

    struct Correction {
        var points: [Point]     // 추정점 전체(만든 순서), 보정된 좌표
        var errM: Double        // 복귀 GPS와 추정 끝점 차이
        var gapS: Double        // 끊긴 시간
    }

    enum Mode { case wait, gps, dr, hold }

    private(set) var mode: Mode = .wait
    private(set) var speed: Double?
    private(set) var course: Double?
    private(set) var last: Fix?
    var p = Params()

    // 센서
    private var yawU: Double?           // 누적 수직축 회전(°, 시계 방향 +), 감기지 않음
    private var lastMotionT: Double?
    private var yawRate = 0.0           // °/s (직진 판정용)
    private var compassTrue: Double?    // 폰 기준 나침반 진북 방위

    // 진행 방향 가속도 치우침 학습
    private var longBias = 0.0
    private var aInt = 0.0
    private var aIntN = 0
    private var hist: [(t: Double, spd: Double, I: Double)] = []
    private var nBias = 0
    private var lastYawAtFix: Double?
    private var aIntAtFix = 0.0         // 마지막 고정점 때의 가속도 적분(정차 판정용)
    private var aIntNAtFix = 0

    private struct DR {
        var t0: Double
        var lastEmit: Double
        var lat0: Double, lon0: Double
        var e: Double, n: Double
        var posT: Double
        var v: Double, v0: Double
        var course0: Double, course: Double
        var yaw0: Double
        var compassOff: Double?
        var dist: Double
        var pts: [(t: Double, e: Double, n: Double, pt: Point)] = []
    }
    private var dr: DR?

    var isEstimating: Bool { dr != nil }
    var gapSeconds: Double? { guard let l = last, mode == .dr, let d = dr else { return nil }; return d.posT - l.t }

    // MARK: 입력

    /// 나침반(폰 방향, 진북 °). 정확도 나쁘면 nil
    func compass(_ trueHeading: Double?) {
        compassTrue = trueHeading.map(norm360)
    }

    /// 센서 한 번(약 25Hz).
    /// - yawRateCW: 수직축 회전 속도(°/s, 위에서 볼 때 시계 방향 +)
    /// - aNorth/aEast: 수평 가속도(m/s², 중력 제외). 모르면 nil → 속도는 직전 GPS 속도로만
    /// 반환: 새로 만든 추정점(보통 0~1개)
    @discardableResult
    func motion(t: Double, yawRateCW: Double, aNorth: Double?, aEast: Double?) -> [Point] {
        guard let lt = lastMotionT else { lastMotionT = t; yawU = 0; return [] }
        var dt = t - lt
        lastMotionT = t
        guard dt > 0 else { return [] }
        // 센서가 한참 안 왔음(앱이 멈췄다 돌아옴) → 그 사이를 직선으로 메우지 않음
        if dr != nil && dt > p.staleSec { dr = nil; mode = .hold; return [] }
        if dt > 0.1 { dt = 0.1 }
        yawU = (yawU ?? 0) + yawRateCW * dt
        yawRate += (yawRateCW - yawRate) * 0.1
        // 진행 방향 성분
        var aLong = 0.0
        if let aN = aNorth, let aE = aEast, let c = (dr?.course ?? course) {
            aLong = aN * cos(c * Self.D) + aE * sin(c * Self.D)
        }
        if dr == nil, aNorth != nil, course != nil { aInt += aLong * dt; aIntN += 1 }
        if dr != nil { drStep(t: t, dt: dt, aLong: aNorth == nil ? nil : aLong) }
        return tick(t)
    }

    /// GPS 좋은 고정점(정확도 통과한 것만). 추정 중이었으면 보정 결과 반환
    func gps(_ f: Fix) -> Correction? {
        // 학습 1) 진행 방향 가속도 치우침: 약 5초 GPS 속도 변화 vs 가속도 적분
        if let s = f.spd {
            hist.append((f.t, s, aInt))
            while hist.count > 2 && f.t - hist[1].t >= 5 { hist.removeFirst() }
            let h0 = hist[0], dt = f.t - h0.t
            if dt >= 4 && dt <= 8 && aIntN > 100 {
                let aGps = (s - h0.spd) / dt, aImu = (aInt - h0.I) / dt
                nBias += 1
                let k = max(0.05, 1 / Double(nBias + 1))
                longBias += ((aImu - aGps) - longBias) * k
            }
        } else { hist = [] }
        var corr: Correction?
        if dr != nil { corr = endDr(f) }
        mode = .gps
        last = f
        lastYawAtFix = yawU
        aIntAtFix = aInt
        aIntNAtFix = aIntN
        speed = f.spd
        if let h = f.hdg { course = h }
        return corr
    }

    /// 기록을 새로 시작/끝낼 때
    func reset() {
        dr = nil; last = nil; mode = .wait; hist = []
    }

    // MARK: 추정

    /// 끊김 판정·1초 간격 추정점 생성
    func tick(_ now: Double) -> [Point] {
        guard let L = last else { return [] }
        let gap = now - L.t
        if var d = dr {
            // 앱이 멈췄다 돌아옴(센서 끊김) 또는 너무 오래 끊김 → 대기
            if now - d.posT > p.staleSec || gap > p.maxGapSec { dr = nil; mode = .hold; return [] }
            var out: [Point] = []
            while now - d.lastEmit >= 1 {
                let t = d.lastEmit + 1
                d.lastEmit = t
                let back = max(0, d.posT - t) * d.v
                let e = d.e - back * sin(d.course * Self.D), n = d.n - back * cos(d.course * Self.D)
                let ll = toLL(e, n, d.lat0, d.lon0)
                let pt = Point(t: t, lat: ll.lat, lon: ll.lon, alt: L.alt,
                               acc: ((L.acc ?? 10) + d.dist * 0.03).rounded(),
                               spd: d.v, hdg: norm360(d.course))
                d.pts.append((t, e, n, pt))
                out.append(pt)
            }
            dr = d
            return out
        }
        guard mode == .gps, gap > p.lossSec else { return [] }
        // 멈춰 있으면 아이폰이 위치를 드문드문 줌 — 끊김이 아님
        if (L.spd ?? 0) < p.minDrSpeed { return [] }
        // 센서가 늦게 깨어남(백그라운드 등): 이미 오래 지났으면 메우지 않음
        if gap > p.lossSec + 2.5 { mode = .hold; return [] }
        guard let spd = L.spd, let hdg = L.hdg, let y = yawU, let y0 = lastYawAtFix else { mode = .hold; return [] }
        // 서서히 멈추는 중(신호 대기 등)이면 마지막 고정점 속도가 아직 빠름 → 그 뒤 진행 방향 가속도로 지금 속도를 다시 셈.
        // 멈췄으면 GPS가 끊긴 게 아니라 위치가 안 바뀐 것 → 추정하지 않음
        var vNow = spd
        if aIntN - aIntNAtFix >= 25 {
            vNow = max(0, min(spd + (aInt - aIntAtFix) - longBias * gap, spd * 1.6 + 8))
            if vNow < p.minDrSpeed { return [] }
        }
        // 끊김은 몇 초 뒤에야 확정 → 마지막 고정점부터 지금까지는 그 속도·방향(+자이로 회전)으로 채움
        let turn = y - y0
        let mid = hdg + turn / 2
        let dd = (spd + vNow) / 2 * gap
        dr = DR(t0: L.t, lastEmit: L.t, lat0: L.lat, lon0: L.lon,
                e: dd * sin(mid * Self.D), n: dd * cos(mid * Self.D), posT: now,
                v: vNow, v0: vNow, course0: hdg, course: hdg + turn, yaw0: y0,
                compassOff: compassTrue.map { wrap(hdg - $0) }, dist: dd)
        mode = .dr
        speed = vNow
        course = norm360(hdg + turn)
        return tick(now)
    }

    private func drStep(t: Double, dt: Double, aLong: Double?) {
        guard var d = dr, let y = yawU else { return }
        var c = d.course0 + (y - d.yaw0)
        // 나침반(긴 끊김 보정): 끊기기 전 거치 각도 그대로, 크게 어긋나면 무시
        if let off = d.compassOff, let ct = compassTrue, t - d.t0 > p.compassAfter {
            let diff = wrap(ct + off - c)
            if abs(diff) < p.compassMaxDiff {
                d.course0 += diff * (dt / p.compassTau)
                c += diff * (dt / p.compassTau)
            }
        }
        d.course = c
        if let a = aLong { d.v += (a - longBias) * dt }
        d.v += (d.v0 - d.v) * (dt / p.speedTau)
        d.v = max(0, min(d.v, d.v0 * 1.6 + 8))
        let step = d.v * dt
        d.posT = t
        d.e += step * sin(c * Self.D)
        d.n += step * cos(c * Self.D)
        d.dist += step
        dr = d
        speed = d.v
        course = norm360(c)
    }

    private func endDr(_ f: Fix) -> Correction? {
        guard let d = dr else { return nil }
        dr = nil
        guard !d.pts.isEmpty else { return nil }
        let g = toEN(f.lat, f.lon, d.lat0, d.lon0)
        let ex = g.e - d.e, ey = g.n - d.n, T = f.t - d.t0
        let fixed: [Point] = d.pts.map { q in
            let k = T > 0 ? min(1, (q.t - d.t0) / T) : 1
            let ll = toLL(q.e + ex * k, q.n + ey * k, d.lat0, d.lon0)
            var pt = q.pt
            pt.lat = ll.lat; pt.lon = ll.lon
            return pt
        }
        return Correction(points: fixed, errM: hypot(ex, ey), gapS: T)
    }

    // MARK: 좌표

    static let D = Double.pi / 180
    static let RE = 6371008.8

    private func toLL(_ e: Double, _ n: Double, _ lat0: Double, _ lon0: Double) -> (lat: Double, lon: Double) {
        (lat0 + (n / Self.RE) / Self.D, lon0 + (e / (Self.RE * cos(lat0 * Self.D))) / Self.D)
    }
    private func toEN(_ lat: Double, _ lon: Double, _ lat0: Double, _ lon0: Double) -> (e: Double, n: Double) {
        ((lon - lon0) * Self.D * Self.RE * cos(lat0 * Self.D), (lat - lat0) * Self.D * Self.RE)
    }
}

@inline(__always) func wrap(_ a: Double) -> Double { ((a.truncatingRemainder(dividingBy: 360)) + 540).truncatingRemainder(dividingBy: 360) - 180 }
@inline(__always) func norm360(_ a: Double) -> Double { ((a.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) }
