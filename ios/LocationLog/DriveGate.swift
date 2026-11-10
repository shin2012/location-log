import Foundation

/// 자동 운전 1초 기록 켜고 끄기 판단 (순수 로직 — 리눅스에서 시뮬 가능). DayLogger 가 사건마다 evaluate 를 부름.
/// - 켜기: 차로 이동 중(CarPlay 연결 또는 기기 동작 '자동차') + 충전 중
/// - 고정(lock): 이번 운전에서 CarPlay 연결과 충전이 한 번이라도 확인되면 운전이 끝날 때까지 충전·동작과 상관없이 1초 유지.
///   끝 = CarPlay 해제 신호 1분 뒤 (그 사이 다시 연결되면 이어감).
///   해제 신호가 안 오면(단축어 누락) '자동차' 아닌 동작이 10분 이어질 때 끝 → 새 CarPlay 연결이나 '자동차' 동작 전까지 다시 안 켬.
/// - 고정 아님('차량 이동', CarPlay 없음): 조건이 풀리면 3분 뒤 끔 (CarPlay 해제 10분 안이면 1분)
/// - 발열로는 끄지 않음 (정밀도만 낮추는 건 Recorder 몫)
struct DriveGate: Codable, Equatable {
    var driving = false
    var lock = false
    var stopAt: Double?             // epoch s — 이때 아직 조건이 안 되면 끔
    var nonCarSince: Double?        // '자동차' 아닌 동작(멈춤·걷기 등, 모름 제외)이 시작된 시각
    var suppressStale = false

    static let lockSafety: Double = 600
    static let lockGrace: Double = 60
    static let rideGrace: Double = 180

    struct Input {
        var now: Double
        var enabled: Bool           // 하루 기록 + '차로 이동 + 충전 중이면 1초 기록' 설정
        var carPlay: Bool
        var carPlaySince: Double?   // 연결 상태가 마지막으로 바뀐 시각
        var charging: Bool
        var activity: DayActivity
    }

    enum Action: Equatable { case none, start, stop }

    /// 새 CarPlay 연결 신호 (안전장치로 끈 뒤 다시 켤 수 있게)
    mutating func carPlayConnected() { suppressStale = false }

    mutating func evaluate(_ i: Input) -> Action {
        if i.activity == .car { nonCarSince = nil; suppressStale = false }
        else if i.activity != .unknown, nonCarSince == nil { nonCarSince = i.now }
        guard i.enabled else { return driving ? end() : .none }

        if !lock && i.carPlay && !suppressStale && (i.charging || driving) { lock = true }
        if lock {
            if i.carPlay {
                if let s = nonCarSince, i.now - s >= Self.lockSafety {
                    suppressStale = true
                    return end()
                }
                stopAt = nil
                return begin()
            }
            return stopAfter(Self.lockGrace, i.now)
        }

        let want = i.charging && (i.carPlay || i.activity == .car) && !suppressStale
        if want { stopAt = nil; return begin() }
        guard driving else { return .none }
        let recentUnplug = !i.carPlay && (i.carPlaySince.map { i.now - $0 < 600 } ?? false)
        return stopAfter(recentUnplug ? Self.lockGrace : Self.rideGrace, i.now)
    }

    private mutating func begin() -> Action {
        if driving { return .none }
        driving = true
        return .start
    }

    private mutating func end() -> Action {
        let was = driving
        driving = false
        lock = false
        stopAt = nil
        return was ? .stop : .none
    }

    private mutating func stopAfter(_ grace: Double, _ now: Double) -> Action {
        guard driving else { lock = false; return .none }
        if let at = stopAt {
            return now >= at ? end() : .none
        }
        stopAt = now + grace
        return .none
    }
}
