// 하루 종일 기록 상태 기계 시뮬레이션 (리눅스):
//   SW=~/.local/swift/swift-6.0.3-RELEASE-ubuntu22.04-aarch64/usr/bin
//   $SW/swiftc -O ios/LocationLog/DayPolicy.swift tools/daysim/main.swift -o /tmp/daysim && /tmp/daysim
// 하루: 집 8h → 걸어서 역 → 지하철(GPS 없음) → 걸어서 회사 → 회사 9h → 차로 귀가(신호 대기) → 집
import Foundation

struct Seg { let dur: Double; let act: DayActivity; let speed: Double; let underground: Bool }

let day: [Seg] = [
    .init(dur: 8 * 3600, act: .stationary, speed: 0, underground: false),
    .init(dur: 600, act: .walk, speed: 1.4, underground: false),
    .init(dur: 1800, act: .car, speed: 10, underground: true),
    .init(dur: 300, act: .walk, speed: 1.4, underground: false),
    .init(dur: 9 * 3600, act: .stationary, speed: 0, underground: false),
    .init(dur: 2400, act: .car, speed: 8, underground: false),  // 신호 대기 포함 (아래에서 2분 정지 반복)
    .init(dur: 5.5 * 3600 + 300, act: .stationary, speed: 0, underground: false),
]

func run(_ opt: DayPolicy.Options, name: String) {
    let p = DayPolicy(options: opt)
    var t = 0.0, x = 0.0  // 동쪽으로만 이동 (m)
    let lat0 = 37.5, lon0 = 127.0
    func pos(_ x: Double) -> (Double, Double) { (lat0, lon0 + x / (111320 * cos(lat0 * .pi / 180))) }
    var lastDeliver: Double?
    var lastDeliverT = -1e9
    var gpsOn = 0.0, pts = 0, fills = 0
    var visits: [DayVisitRec] = []
    var departures: [(truth: Double, detected: Double)] = []
    var lastAct = DayActivity.unknown
    var pendingMotion: (DayActivity, Double)?
    var segStartT = 0.0
    var inStay = false
    var due: Double? = nil
    var lastPhase = DayPolicy.Phase.moving
    var lastPts = -1

    func handle(_ evs: [DayEvent]) {
        for e in evs {
            switch e {
            case .point(let q): pts += 1; if q.src == "fill" { fills += 1 }
            case .arrived(let v): visits.append(v)
            case .departed(let v):
                if let i = visits.lastIndex(where: { $0.arrive == v.arrive }) { visits[i] = v } else { visits.append(v) }
                departures.append((segStartT, t))
            }
        }
    }

    var segIdx = 0
    var segT = 0.0
    let total = day.reduce(0) { $0 + $1.dur }
    while t < total {
        let seg = day[segIdx]
        // 신호 대기: 차량 구간에서 3분마다 1분 정지
        var v = seg.speed
        if seg.act == .car && !seg.underground && Int(segT) % 180 >= 120 { v = 0 }
        x += v
        // 움직임 감지: 구간 바뀌고 20초 뒤 알림
        if seg.act != lastAct, pendingMotion == nil { pendingMotion = (seg.act, t + 20) }
        if let (a, at) = pendingMotion, t >= at {
            handle(p.motion(a, start: segStartT, now: t)); lastAct = a; pendingMotion = nil
        }
        // 위치 관리자 흉내
        let c = p.config
        if c.gpsOn || c.acc == .hundred { gpsOn += 1 }
        let (la, lo) = pos(x)
        switch c.acc {
        case .off: break
        case .coarse:
            if lastDeliver == nil || abs(x - lastDeliver!) >= 500 {
                lastDeliver = x; handle(p.fix(.init(t: t, lat: la, lon: lo, acc: 65)))
            }
        default:
            if !seg.underground && (lastDeliver == nil || abs(x - lastDeliver!) >= max(c.distance, 0.01) || (c.distance == 0 && t - lastDeliverT >= 1)) {
                lastDeliver = x; lastDeliverT = t
                handle(p.fix(.init(t: t, lat: la, lon: lo, acc: c.acc == .hundred ? 30 : 8, spd: v)))
            }
        }
        // 앱과 같게: 사건이 있을 때마다 다음 깨울 시각을 다시 잡음
        if p.phase != lastPhase || pts != lastPts { due = p.nextTick(now: t); lastPhase = p.phase; lastPts = pts }
        if let d = due, d <= t { handle(p.tick(t)); due = p.nextTick(now: t); lastPhase = p.phase }
        t += 1; segT += 1
        if segT >= seg.dur, segIdx + 1 < day.count {
            segIdx += 1; segT = 0; segStartT = t
            _ = inStay; inStay = day[segIdx].act == .stationary
        }
    }
    let fmt = { (s: Double) in String(format: "%02d:%02d", Int(s) / 3600, Int(s) % 3600 / 60) }
    print("── \(name)")
    print("  GPS(정밀) 켜진 시간: \(fmt(gpsOn)) / 24:00 (\(String(format: "%.1f", gpsOn / total * 100))%)  점 \(pts)개 (메움 \(fills))")
    for v in visits {
        print("  머문 곳 \(fmt(v.arrive / 1000))–\(v.depart.map { fmt($0 / 1000) } ?? "…")")
    }
    for d in departures { print("  출발 실제 \(fmt(d.truth)) → 알아챔 \(fmt(d.detected)) (\(Int(d.detected - d.truth))초)") }
}

run(.init(), name: "균형 · 기본 (움직임 감지 + 10분 확인)")
run(.init(motionWake: false), name: "균형 · 움직임 감지 끔 (10분 확인만)")
run(.init(motionWake: false, checkMinutes: 0), name: "균형 · 움직임 감지·주기 확인 끔")
run(.init(level: .save), name: "절약")
run(.init(level: .precise, checkMinutes: 5), name: "정밀 · 5분 확인")
