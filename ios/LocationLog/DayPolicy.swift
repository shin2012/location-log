import Foundation

/// 하루 종일 기록의 상태 기계 (순수 Foundation → 리눅스에서 시뮬 가능: tools/daysim)
///
/// 배터리 원칙: 머무는 동안은 GPS를 끄고(저정확도 위치로 앱만 깨워 둠),
/// 움직임 감지 칩·주기 확인·위치 변화로 출발을 알아채면 그때 GPS를 켬.
/// 움직이는 동안도 이동 수단에 맞춰 정확도·거리 간격을 낮춤.

enum DayActivity: String, Codable, CaseIterable {
    case stationary, walk, run, bike, car, unknown

    var moving: Bool { self == .walk || self == .run || self == .bike || self == .car }

    var label: String {
        switch self {
        case .stationary: return "머무는 중"
        case .walk: return "걷는 중"
        case .run: return "달리는 중"
        case .bike: return "자전거"
        case .car: return "차량 이동"
        case .unknown: return "이동 중"
        }
    }
}

/// 기록 단계: 움직이는 동안 GPS를 얼마나 정밀하게 쓸지
enum DayLevel: String, Codable, CaseIterable, Identifiable {
    case save, balanced, precise
    var id: String { rawValue }

    var label: String {
        switch self {
        case .save: return "절약"
        case .balanced: return "균형"
        case .precise: return "정밀"
        }
    }

    var detail: String {
        switch self {
        case .save: return "움직일 때도 낮은 정확도(약 100m), 100m 간격"
        case .balanced: return "이동 수단에 맞춰 조절 (걷기 20m · 자전거 30m · 차량 50m 간격)"
        case .precise: return "가장 높은 정확도, 10m 간격 — 배터리 많이 씀"
        }
    }
}

/// 위치 관리자에 줄 설정
struct DayGPSConfig: Equatable {
    enum Acc: String { case off, coarse, hundred, ten, best }
    var acc: Acc
    var distance: Double      // m, 0 = 거르지 않음

    /// GPS 칩을 켜는 설정인지 (통계용)
    var gpsOn: Bool { acc == .ten || acc == .best }

    static let off = DayGPSConfig(acc: .off, distance: 0)
    static let keepAlive = DayGPSConfig(acc: .coarse, distance: 500)
    static let check = DayGPSConfig(acc: .best, distance: 0)
}

struct DayFix {
    var t: Double             // epoch s
    var lat: Double
    var lon: Double
    var acc: Double           // m
    var spd: Double? = nil
    var alt: Double? = nil
    var src: String = "gps"   // gps | visit | slc | region | trk
}

struct DayPoint: Codable, Hashable {
    var ts: Double            // epoch ms
    var lat: Double
    var lon: Double
    var alt: Double?
    var acc: Double?
    var spd: Double?
    var src: String
    var act: String?
}

struct DayVisitRec: Codable, Hashable {
    var arrive: Double        // epoch ms
    var depart: Double?
    var lat: Double
    var lon: Double
}

enum DayEvent: Equatable {
    case point(DayPoint)
    case arrived(DayVisitRec)          // 머물기 시작 (depart = nil)
    case departed(DayVisitRec)         // 머물기 끝
}

final class DayPolicy {
    struct Options: Equatable {
        var level: DayLevel = .balanced
        var keepAlive = true           // 머무는 동안 저정확도 위치로 앱을 깨워 둠 (움직임 감지·주기 확인에 필요)
        var motionWake = true          // 움직임 감지로 출발 알아채기
        var checkMinutes = 10          // 머무는 동안 GPS 확인 간격, 0 = 끔
        var fillGap = true             // 출발 구간 메우기
        var stayMinutes = 5            // 이만큼 반경 안에 있으면 머무는 것으로
        var stayRadius: Double = 100   // m
        var movingDistance: Double = 0 // m, 0 = 단계 기본
        var maxAcc: Double = 100       // m, 이보다 나쁜 위치는 안 씀

        static let probeTimeout: Double = 180   // s — 움직임 감지 뒤 이만큼 안 벗어나면 다시 머묾
        static let stillOff: Double = 120       // s — 확인 중 이만큼 계속 멈춰 있어야 GPS 끔 (엘리베이터 앞 3초 멈춤은 무시)
        static let probeBufMax = 400            // 확인 중 모아 두는 반경 안 점 최대 수
        static let checkTimeout: Double = 30    // s — 주기 확인 GPS 최대 시간
        static let checkGoodAcc: Double = 25    // m — 이 정도면 확인 끝
        static let maxSpeed: Double = 70        // m/s 순간 이동 거름
    }

    enum Phase: String, Codable { case moving, stationary, probing, checking }

    /// 앱이 꺼졌다 다시 켜져도 이어지도록 저장하는 상태
    struct State: Codable {
        var phase: Phase = .moving
        var activity: DayActivity = .unknown
        var activityStart: Double?     // 지금 움직임이 시작된 시각 (움직임 감지)
        // 움직이는 중: 이 점에서 stayRadius 안에 계속 있으면 머묾
        var anchorLat: Double?, anchorLon: Double?, anchorT: Double?
        var anchorSumLat = 0.0, anchorSumLon = 0.0, anchorN = 0
        // 머무는 곳
        var centerLat: Double?, centerLon: Double?, stayStart: Double?
        var lastCheck: Double = 0
        var phaseStart: Double = 0     // probing/checking 시작
        var bestCheckFix: Double?      // checking 중 받은 가장 좋은 정확도
        // 마지막 저장 점
        var lastLat: Double?, lastLon: Double?, lastT: Double?
        // 멈춤이 시작된 시각 (움직임 감지 'stationary'). 짧은 멈춤 판정·확인 중 GPS 끄기에 씀
        var stopAt: Double?
        // 확인(probing) 중 머문 곳 반경 안에서 받은 점 — 떠난 것으로 판정되면 경로 앞에 붙이고, 아니면 버림
        var probeBuf: [DayPoint]?
    }

    var opt: Options
    private(set) var s: State

    init(options: Options = .init(), state: State = .init()) {
        opt = options
        s = state
    }

    var phase: Phase { s.phase }
    var activity: DayActivity { s.activity }

    /// 지금 위치 관리자에 줄 설정
    var config: DayGPSConfig {
        switch s.phase {
        case .stationary: return opt.keepAlive ? .keepAlive : .off
        case .checking: return .check
        case .moving, .probing: return movingConfig
        }
    }

    var movingConfig: DayGPSConfig {
        var c: DayGPSConfig
        switch opt.level {
        case .save: c = .init(acc: .hundred, distance: 100)
        case .precise: c = .init(acc: .best, distance: 10)
        case .balanced:
            switch s.activity {
            case .walk, .run: c = .init(acc: .ten, distance: 20)
            case .bike: c = .init(acc: .ten, distance: 30)
            case .car: c = .init(acc: .hundred, distance: 50)
            case .stationary, .unknown: c = .init(acc: .ten, distance: 30)
            }
        }
        if opt.movingDistance > 0 { c.distance = opt.movingDistance }
        return c
    }

    /// 다음에 tick()을 불러야 하는 시각 (없으면 nil)
    func nextTick(now: Double) -> Double? {
        switch s.phase {
        case .moving:
            // 거리 간격 때문에 멈추면 위치가 안 옴 → 머묾 판정은 시계로
            guard let a = s.anchorT else { return now + 60 }
            return max(now + 5, a + Double(opt.stayMinutes) * 60 + 1)
        case .probing:
            var at = s.phaseStart + Options.probeTimeout
            if s.activity == .stationary, let st = s.stopAt { at = min(at, max(now + 5, st + Options.stillOff)) }
            return at
        case .checking: return s.phaseStart + Options.checkTimeout
        case .stationary:
            guard opt.keepAlive, opt.checkMinutes > 0 else { return nil }
            return max(now + 5, s.lastCheck + Double(opt.checkMinutes) * 60)
        }
    }

    // MARK: 입력

    func tick(_ now: Double) -> [DayEvent] {
        switch s.phase {
        case .moving:
            if let a = s.anchorT, now - a >= Double(opt.stayMinutes) * 60, !(opt.motionWake && s.activity.moving && s.activity != .walk) {
                // 차량 신호 대기 등 '움직임 중'으로 감지되면 머묾으로 안 봄 (걷기는 실내에서도 나오므로 예외)
                return becomeStationary(now)
            }
        case .probing:
            if now - s.phaseStart >= Options.probeTimeout { backToStay(now) }
            else if s.activity == .stationary, let st = s.stopAt, now - st >= Options.stillOff { backToStay(now) }
        case .checking:
            if now - s.phaseStart >= Options.checkTimeout { backToStay(now) }
        case .stationary:
            if opt.keepAlive, opt.checkMinutes > 0, now - s.lastCheck >= Double(opt.checkMinutes) * 60 {
                s.phase = .checking
                s.phaseStart = now
                s.bestCheckFix = nil
            }
        }
        return []
    }

    /// 경계 벗어남·기지국 변화 등 OS가 깨워 줌 → 머무는 중이면 GPS로 확인
    func nudge(_ now: Double) -> [DayEvent] {
        if s.phase == .stationary {
            s.phase = .checking
            s.phaseStart = now
            s.bestCheckFix = nil
        }
        return []
    }

    /// 머무는 곳 (경계 등록용)
    var stayCenter: (lat: Double, lon: Double)? {
        guard let a = s.centerLat, let b = s.centerLon else { return nil }
        return (a, b)
    }

    /// 움직임 감지 칩 (CMMotionActivity)
    func motion(_ a: DayActivity, start: Double, now: Double) -> [DayEvent] {
        let was = s.activity
        s.activity = a
        if a.moving, !was.moving {
            // 2분 안 된 멈춤 뒤 다시 움직임 → 같은 움직임으로 봄 (처음 움직이기 시작한 시각 유지)
            let blip = s.stopAt.map { start - $0 < Options.stillOff } ?? false
            if !(blip && s.activityStart != nil) { s.activityStart = start }
            s.stopAt = nil
        } else if a == .stationary, was != .stationary {
            s.stopAt = start
        }
        guard opt.motionWake else { return [] }
        switch s.phase {
        case .stationary, .checking:
            if a.moving {
                s.phase = .probing
                s.phaseStart = now
                s.probeBuf = []
            }
        case .probing:
            break      // 멈춤은 2분 이어져야 끔 (tick)
        case .moving:
            break
        }
        return []
    }

    func fix(_ f: DayFix) -> [DayEvent] {
        guard f.acc >= 0, f.acc <= opt.maxAcc else { return [] }
        switch s.phase {
        case .moving:
            return onMovingFix(f)
        case .stationary, .probing, .checking:
            guard let cLat = s.centerLat, let cLon = s.centerLon else { return startMoving(f, departAt: f.t) }
            let d = DayGeo.dist(cLat, cLon, f.lat, f.lon)
            let precise = f.acc <= 50 || f.src == "trk"
            if d > max(opt.stayRadius, f.acc) + (precise ? 0 : opt.stayRadius) {
                if precise || s.phase != .stationary {
                    return depart(f)
                }
                // 머무는 중 낮은 정확도 위치가 멀리 나옴 → GPS로 확인
                s.phase = .checking
                s.phaseStart = f.t
                s.bestCheckFix = nil
                return []
            }
            if s.phase == .checking {
                s.bestCheckFix = min(s.bestCheckFix ?? .infinity, f.acc)
                if f.acc <= Options.checkGoodAcc { backToStay(f.t) }
            }
            if s.phase == .probing, precise {
                var b = s.probeBuf ?? []
                if b.count < Options.probeBufMax {
                    b.append(DayPoint(ts: f.t * 1000, lat: f.lat, lon: f.lon, alt: f.alt, acc: f.acc, spd: f.spd,
                                      src: f.src, act: s.activity.rawValue))
                    s.probeBuf = b
                }
            }
            return []
        }
    }

    // MARK: 내부

    private func onMovingFix(_ f: DayFix) -> [DayEvent] {
        var out: [DayEvent] = []
        if let aLat = s.anchorLat, let aLon = s.anchorLon, let aT = s.anchorT,
           DayGeo.dist(aLat, aLon, f.lat, f.lon) <= max(opt.stayRadius, f.acc) {
            s.anchorSumLat += f.lat; s.anchorSumLon += f.lon; s.anchorN += 1
            if f.t - aT >= Double(opt.stayMinutes) * 60, !(opt.motionWake && s.activity.moving && s.activity != .walk) {
                out += store(f)
                out += becomeStationary(f.t)
                return out
            }
        } else {
            setAnchor(f)
        }
        out += store(f)
        return out
    }

    private func setAnchor(_ f: DayFix) {
        s.anchorLat = f.lat; s.anchorLon = f.lon; s.anchorT = f.t
        s.anchorSumLat = f.lat; s.anchorSumLon = f.lon; s.anchorN = 1
    }

    private func store(_ f: DayFix) -> [DayEvent] {
        if let lt = s.lastT, let la = s.lastLat, let lo = s.lastLon {
            let dt = f.t - lt
            if dt <= 0 { return [] }
            let d = DayGeo.dist(la, lo, f.lat, f.lon)
            if d / dt > Options.maxSpeed && dt < 120 { return [] }
            // 거리로 솎지 않음: 받은 점은 모두 저장. 덜 받는 건 iOS 정확도·거리 설정(movingConfig)이 맡음 — 받은 뒤 버리면 배터리 이득 없음
        }
        s.lastLat = f.lat; s.lastLon = f.lon; s.lastT = f.t
        return [.point(DayPoint(ts: f.t * 1000, lat: f.lat, lon: f.lon, alt: f.alt, acc: f.acc, spd: f.spd,
                                src: f.src, act: s.activity.rawValue))]
    }

    private func becomeStationary(_ now: Double) -> [DayEvent] {
        guard let aT = s.anchorT, s.anchorN > 0 else {
            // 위치를 아직 한 번도 못 받음 → 계속 기다림
            return []
        }
        let lat = s.anchorSumLat / Double(s.anchorN), lon = s.anchorSumLon / Double(s.anchorN)
        s.phase = .stationary
        s.centerLat = lat; s.centerLon = lon; s.stayStart = aT
        s.lastCheck = now
        s.anchorLat = nil; s.anchorLon = nil; s.anchorT = nil; s.anchorN = 0
        return [.arrived(DayVisitRec(arrive: aT * 1000, depart: nil, lat: lat, lon: lon))]
    }

    private func backToStay(_ now: Double) {
        s.phase = .stationary
        s.lastCheck = now
        s.bestCheckFix = nil
        s.probeBuf = nil
    }

    private func depart(_ f: DayFix) -> [DayEvent] {
        var depAt = f.t
        if let a = s.activityStart, let st = s.stayStart, a > st, a < f.t, f.t - a < 1800 { depAt = a }
        return startMoving(f, departAt: depAt)
    }

    private func startMoving(_ f: DayFix, departAt: Double) -> [DayEvent] {
        var out: [DayEvent] = []
        let buf = s.probeBuf ?? []
        s.probeBuf = nil
        if let cLat = s.centerLat, let cLon = s.centerLon, let st = s.stayStart {
            out.append(.departed(DayVisitRec(arrive: st * 1000, depart: departAt * 1000, lat: cLat, lon: cLon)))
            if opt.fillGap, departAt < f.t {
                // 머물던 자리에서 출발한 시각에 점 하나 → 첫 GPS 점까지 이어짐
                out.append(.point(DayPoint(ts: departAt * 1000, lat: cLat, lon: cLon, alt: nil, acc: nil, spd: nil,
                                           src: "fill", act: s.activity.rawValue)))
                s.lastLat = cLat; s.lastLon = cLon; s.lastT = departAt
            }
            // 확인 중 반경 안에서 받은 점 중 떠난 뒤 것 → 경로 앞부분 (현관 → 차)
            for q in buf where q.ts >= departAt * 1000 && q.ts < f.t * 1000 {
                out += store(DayFix(t: q.ts / 1000, lat: q.lat, lon: q.lon, acc: q.acc ?? 50, spd: q.spd, alt: q.alt, src: q.src))
            }
        }
        s.phase = .moving
        s.centerLat = nil; s.centerLon = nil; s.stayStart = nil
        setAnchor(f)
        out += store(f)
        return out
    }
}

enum DayGeo {
    static func dist(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = 6371008.8, p = Double.pi / 180
        let a = sin((la2 - la1) * p / 2), b = sin((lo2 - lo1) * p / 2)
        let h = a * a + cos(la1 * p) * cos(la2 * p) * b * b
        return 2 * r * asin(min(1, h.squareRoot()))
    }
}
