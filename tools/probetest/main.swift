// 확인(probing) 중 짧은 멈춤·반경 안 점 붙이기 시험 (리눅스):
//   SW=~/.local/swift/swift-6.0.3-RELEASE-ubuntu22.04-aarch64/usr/bin
//   $SW/swiftc -O ios/LocationLog/DayPolicy.swift tools/probetest/main.swift -o /tmp/probetest && /tmp/probetest
// 2026-11-10 출근길: 걷기 07:16:14 → 멈춤 07:18:55(3초) → 걷기 07:18:58 → 반경 밖 07:19:16
import Foundation

let lat0 = 37.59456, lon0 = 126.94220
func east(_ m: Double) -> Double { lon0 + m / (111320 * cos(lat0 * .pi / 180)) }
var fails = 0
func check(_ ok: Bool, _ msg: String) { print(ok ? "ok  " : "FAIL", msg); if !ok { fails += 1 } }

func stayed() -> DayPolicy {
    let p = DayPolicy()
    var t = 0.0
    while p.phase != .stationary && t < 900 {
        _ = p.fix(DayFix(t: t, lat: lat0, lon: lon0, acc: 10))
        _ = p.tick(t)
        t += 30
    }
    _ = p.motion(.stationary, start: t, now: t)
    return p
}

// 1) 출근길: 짧은 멈춤은 무시, 떠난 시각 = 처음 걷기, 반경 안 점이 경로 앞에 붙음
do {
    let p = stayed()
    let T0 = 10_000.0
    _ = p.motion(.walk, start: T0, now: T0 + 20)
    check(p.phase == .probing, "걷기 → 확인 시작")
    var evs: [DayEvent] = []
    for i in 0..<8 { evs += p.fix(DayFix(t: T0 + 30 + Double(i) * 15, lat: lat0, lon: east(Double(i) * 8), acc: 8)) }
    _ = p.motion(.stationary, start: T0 + 161, now: T0 + 161)
    evs += p.tick(T0 + 164)
    check(p.phase == .probing, "3초 멈춤 → 확인 유지 (지금은 바로 꺼짐)")
    _ = p.motion(.walk, start: T0 + 164, now: T0 + 165)
    evs += p.fix(DayFix(t: T0 + 175, lat: lat0, lon: east(70), acc: 8))
    evs += p.fix(DayFix(t: T0 + 182, lat: lat0, lon: east(130), acc: 8))
    var dep: Double?, pts: [DayPoint] = []
    for e in evs {
        if case .departed(let v) = e { dep = v.depart }
        if case .point(let q) = e { pts.append(q) }
    }
    check(dep == T0 * 1000, "떠난 시각 = 처음 걷기 (\(dep.map { ($0 / 1000 - T0) } ?? -1)초 차이)")
    let inner = pts.filter { $0.src == "gps" && $0.ts < (T0 + 182) * 1000 }.count
    check(inner >= 3, "반경 안 점 \(inner)개 경로에 붙음 (10m 간격으로 솎음, 지금은 0개)")
    check(pts.first?.src == "fill", "출발점(fill)이 맨 앞")
    check(zip(pts, pts.dropFirst()).allSatisfy { $0.ts < $1.ts }, "점 시간순")
}

// 2) 2분 넘게 멈춤 → GPS 끔, 모아 둔 점 버림
do {
    let p = stayed()
    let T0 = 10_000.0
    _ = p.motion(.walk, start: T0, now: T0)
    _ = p.fix(DayFix(t: T0 + 10, lat: lat0, lon: east(10), acc: 8))
    _ = p.motion(.stationary, start: T0 + 30, now: T0 + 30)
    _ = p.tick(T0 + 100)
    check(p.phase == .probing, "멈춤 70초 → 아직 확인 중")
    let nt = p.nextTick(now: T0 + 100) ?? 0
    check(abs(nt - (T0 + 150)) < 1, "다음 확인 = 멈춤 2분 시점 (\(nt - T0))")
    _ = p.tick(T0 + 150)
    check(p.phase == .stationary, "멈춤 2분 → GPS 끔")
    check(p.s.probeBuf == nil, "모아 둔 점 버림")
}

// 3) 3분 상한 그대로
do {
    let p = stayed()
    let T0 = 10_000.0
    _ = p.motion(.walk, start: T0, now: T0)
    _ = p.tick(T0 + 179)
    check(p.phase == .probing, "179초 → 확인 중")
    _ = p.tick(T0 + 180)
    check(p.phase == .stationary, "180초 → 끔 (3분 유지)")
}

// 4) 긴 멈춤 뒤 다시 걷기 → 떠난 시각은 새 걷기
do {
    let p = stayed()
    _ = p.motion(.walk, start: 9_000, now: 9_000)
    _ = p.motion(.stationary, start: 9_050, now: 9_050)
    _ = p.tick(9_200)
    _ = p.motion(.walk, start: 10_000, now: 10_000)
    var dep: Double?
    for e in p.fix(DayFix(t: 10_060, lat: lat0, lon: east(150), acc: 8)) { if case .departed(let v) = e { dep = v.depart } }
    check(dep == 10_000 * 1000, "긴 멈춤 뒤 → 새 걷기 시각")
}
print(fails == 0 ? "ALL OK" : "\(fails) FAIL")
exit(fails == 0 ? 0 : 1)
