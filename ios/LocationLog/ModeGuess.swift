import Foundation

/// 수동 경로 기록이 끝났을 때 이동 수단 자동 인식 (순수 로직 — 리눅스에서 시험 가능).
/// 서버 타임라인 move_mode 와 같은 규칙: 기록 구간에서 가장 오래 이어진 움직임(2분 미만 무시) → 없으면 평균 속도.
enum ModeGuess {
    struct Act { let start: Double; let kind: String }   // 동작이 시작된 시각(epoch s), car|bike|run|walk|stationary|unknown

    static let minSeconds: Double = 120

    /// acts: 시간순 (t0 이전에 시작한 마지막 하나 포함 가능). km/secs = 기록 거리·시간
    static func decide(acts: [Act], t0: Double, t1: Double, km: Double) -> TravelMode {
        var dur: [String: Double] = [:]
        for (i, a) in acts.enumerated() {
            let s = max(a.start, t0)
            let e = min(i + 1 < acts.count ? acts[i + 1].start : t1, t1)
            guard e > s else { continue }
            let k = a.kind == "run" ? "walk" : a.kind
            dur[k, default: 0] += e - s
        }
        let moving = dur.filter { ["car", "walk", "bike"].contains($0.key) && $0.value >= minSeconds }
        if let best = moving.max(by: { $0.value < $1.value }) {
            switch best.key {
            case "car": return .car
            case "bike": return .bicycle
            default: return .walk
            }
        }
        let secs = t1 - t0
        guard secs > 0 else { return .other }
        let kmh = km / (secs / 3600)
        if kmh >= 20 { return .car }
        if kmh < 8 { return .walk }
        return .other
    }
}
