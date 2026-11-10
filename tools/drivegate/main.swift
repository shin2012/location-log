// 자동 운전 고정·이동 수단 인식 시험:
//   swiftc ios/LocationLog/DayPolicy.swift ios/LocationLog/DriveGate.swift ios/LocationLog/ModeGuess.swift \
//          tools/drivegate/stub.swift tools/drivegate/main.swift -o /tmp/drivegate && /tmp/drivegate
import Foundation

var fails = 0
func check(_ ok: Bool, _ msg: String) {
    print((ok ? "ok   " : "FAIL ") + msg)
    if !ok { fails += 1 }
}

/// 초 단위 시나리오: 매초 evaluate (앱은 1초 기록 중 위치마다 부름)
struct Sim {
    var g = DriveGate()
    var t: Double = 0
    var carPlay = false, carPlaySince: Double? = nil, charging = false, act: DayActivity = .unknown
    var log: [(Double, DriveGate.Action)] = []
    mutating func setCarPlay(_ on: Bool) {
        if on != carPlay { carPlay = on; carPlaySince = t; if on { g.carPlayConnected() } }
    }
    mutating func run(_ secs: Int) {
        for _ in 0..<secs {
            let a = g.evaluate(.init(now: t, enabled: true, carPlay: carPlay, carPlaySince: carPlaySince, charging: charging, activity: act))
            if a != .none { log.append((t, a)) }
            t += 1
        }
    }
}

// 1) CarPlay + 충전 → 고정, 충전 깜빡임·충전 끊김에도 유지, 해제 1분 뒤 끝
do {
    var s = Sim()
    s.act = .car; s.charging = true; s.setCarPlay(true); s.run(60)
    check(s.g.driving && s.g.lock, "CarPlay+충전 → 1초 기록 + 고정")
    for _ in 0..<5 { s.charging = false; s.run(20); s.charging = true; s.run(5) }
    s.charging = false; s.run(900)
    check(s.g.driving && s.log.count == 1, "충전 깜빡임·끊김 15분 → 계속 유지 (켜짐 1번)")
    s.act = .stationary; s.run(300)
    check(s.g.driving, "신호 대기 5분 (CarPlay 연결 중) → 유지")
    s.act = .car; s.run(60)
    s.setCarPlay(false); s.run(59)
    check(s.g.driving, "CarPlay 해제 59초 → 아직 유지")
    s.run(3)
    check(!s.g.driving && !s.g.lock, "CarPlay 해제 1분 뒤 → 끝, 고정 풀림")
}

// 2) 해제 뒤 1분 안 재연결 → 같은 운전으로 이어감
do {
    var s = Sim()
    s.act = .car; s.charging = true; s.setCarPlay(true); s.run(120)
    s.charging = false
    s.setCarPlay(false); s.run(30); s.setCarPlay(true); s.run(300)
    check(s.g.driving && s.g.lock && s.log.count == 1, "해제 30초 뒤 재연결 (충전 없음) → 끊기지 않고 고정 유지")
}

// 3) 해제 신호 누락: '자동차' 아닌 동작 10분 → 끝, 그 뒤 stale 연결로 다시 안 켬
do {
    var s = Sim()
    s.act = .car; s.charging = true; s.setCarPlay(true); s.run(600)
    s.act = .walk; s.run(599)
    check(s.g.driving, "해제 신호 없음 + 걷기 9분 59초 → 아직 유지")
    s.run(2)
    check(!s.g.driving, "걷기 10분 → 안전장치로 끝")
    s.act = .stationary; s.run(3600)
    check(!s.g.driving, "연결 상태가 남아 있어도(신호 누락) + 충전 중 → 다시 안 켬")
    s.act = .car; s.run(5)
    check(s.g.driving && s.g.lock, "다시 '자동차' → 새 운전 시작·고정")
}

// 4) 동작 기록 없음(모름): 안전장치가 잘못 끄지 않음
do {
    var s = Sim()
    s.act = .unknown; s.charging = true; s.setCarPlay(true); s.run(3600)
    check(s.g.driving && s.log.count == 1, "동작 '모름' 1시간 + CarPlay 연결 → 유지")
}

// 5) 차량 이동 (CarPlay 없음) = 현행: 충전 빠지면 3분 뒤 끔
do {
    var s = Sim()
    s.act = .car; s.charging = true; s.run(300)
    check(s.g.driving && !s.g.lock, "충전 + 자동차 (CarPlay 없음) → 1초 기록, 고정 아님")
    s.charging = false; s.run(179)
    check(s.g.driving, "충전 빠짐 2분 59초 → 아직")
    s.run(2)
    check(!s.g.driving, "충전 빠짐 3분 → 끔 (현행)")
    s.charging = true; s.run(60); s.charging = false; s.run(60); s.charging = true; s.run(60)
    check(s.g.driving && s.log.filter { $0.1 == .stop }.count == 1, "3분 안 충전 다시 → 끊기지 않음")
}

// 6) 차량 이동 중 CarPlay 연결 → 고정 (충전은 시작 때 확인됨)
do {
    var s = Sim()
    s.act = .car; s.charging = true; s.run(60)
    s.charging = false; s.run(30)
    s.setCarPlay(true); s.run(10)
    check(s.g.driving && s.g.lock, "충전으로 시작한 차량 이동 중 CarPlay 연결 → 고정")
    s.run(1200)
    check(s.g.driving, "고정 뒤 충전 없이 20분 → 유지")
}

// 7) CarPlay만 (충전 없음) → 안 켬, 나중에 충전되면 켬·고정
do {
    var s = Sim()
    s.act = .car; s.setCarPlay(true); s.run(300)
    check(!s.g.driving && !s.g.lock, "CarPlay만, 충전 없음 → 안 켬")
    s.charging = true; s.run(1)
    check(s.g.driving && s.g.lock, "충전 연결 → 켜고 고정")
}

// 8) 설정 끔 → 바로 끔
do {
    var s = Sim()
    s.act = .car; s.charging = true; s.setCarPlay(true); s.run(10)
    let a = s.g.evaluate(.init(now: s.t, enabled: false, carPlay: true, carPlaySince: 0, charging: true, activity: .car))
    check(a == .stop && !s.g.driving && !s.g.lock, "설정 끄면 바로 끝")
}

// 9) 저장·복원 (앱 재시작)
do {
    var s = Sim()
    s.act = .car; s.charging = true; s.setCarPlay(true); s.run(10)
    let d = try! JSONEncoder().encode(s.g)
    let g2 = try! JSONDecoder().decode(DriveGate.self, from: d)
    check(g2 == s.g && g2.lock, "상태 저장·복원")
}

// 이동 수단 자동 인식
do {
    typealias A = ModeGuess.Act
    let t0 = 1000.0
    check(ModeGuess.decide(acts: [A(start: t0 - 50, kind: "walk"), A(start: t0 + 200, kind: "car"), A(start: t0 + 1500, kind: "walk")],
                           t0: t0, t1: t0 + 1700, km: 10) == .car, "걷기 3분 + 차 22분 → 차량")
    check(ModeGuess.decide(acts: [A(start: t0, kind: "run"), A(start: t0 + 1200, kind: "stationary")],
                           t0: t0, t1: t0 + 1300, km: 3) == .walk, "달리기 20분 → 도보")
    check(ModeGuess.decide(acts: [A(start: t0, kind: "bike")], t0: t0, t1: t0 + 900, km: 4) == .bicycle, "자전거 15분 → 자전거")
    check(ModeGuess.decide(acts: [A(start: t0, kind: "car"), A(start: t0 + 100, kind: "walk")],
                           t0: t0, t1: t0 + 110, km: 0.1) == .walk, "2분 미만 차 동작은 무시 → 속도 3km/h → 도보")
    check(ModeGuess.decide(acts: [], t0: t0, t1: t0 + 1800, km: 20) == .car, "동작 기록 없음 40km/h → 차량")
    check(ModeGuess.decide(acts: [], t0: t0, t1: t0 + 1800, km: 2) == .walk, "동작 기록 없음 4km/h → 도보")
    check(ModeGuess.decide(acts: [], t0: t0, t1: t0 + 3600, km: 12) == .other, "동작 기록 없음 12km/h → 기타")
}

print(fails == 0 ? "ALL OK" : "\(fails) FAIL")
exit(fails == 0 ? 0 : 1)
