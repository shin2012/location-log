import Foundation

/// 주차 층 추정 (순수 로직). 서버 server/parking.py 와 같은 규칙 — 바꾸면 둘 다.
/// level: 지상 1층 = 0, 2층 = 1 …, 지하 1층 = -1 … / dh: 지상 도로 대비 높이 차 m (내려가면 음수)
/// 모델 dh ≈ a·level + b. 사용자가 고친 주차 중 150m 안 것으로 장소별 a(층 높이)·b(입구 높이) 맞춤.
struct ParkCal: Codable, Equatable, Sendable {
    let lat: Double
    let lon: Double
    let dh: Double
    let level: Int
}

enum ParkModel {
    static let hScale = 8434.0
    static let defA = 3.2
    static let aMin = 2.0, aMax = 6.0
    static let nearM = 150.0
    static let levelMin = -9, levelMax = 30

    static func dh(refKpa: Double, nowKpa: Double) -> Double { hScale * log(refKpa / nowKpa) }

    static func label(_ level: Int) -> String { level < 0 ? "B\(-level)" : "\(level + 1)F" }

    static func dist(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = Double.pi / 180
        let a = sin((la2 - la1) * r / 2), b = sin((lo2 - lo1) * r / 2)
        let h = a * a + cos(la1 * r) * cos(la2 * r) * b * b
        return 2 * 6371008.8 * asin(min(1, h.squareRoot()))
    }

    static func globalA(_ cal: [ParkCal]) -> Double {
        let r = cal.compactMap { c -> Double? in
            guard c.level != 0 else { return nil }
            let x = c.dh / Double(c.level)
            return x >= aMin && x <= aMax ? x : nil
        }.sorted()
        guard !r.isEmpty else { return defA }
        let n = r.count
        return n % 2 == 1 ? r[n / 2] : (r[n / 2 - 1] + r[n / 2]) / 2
    }

    static func model(lat: Double, lon: Double, cal: [ParkCal]) -> (a: Double, b: Double) {
        let g = globalA(cal)
        let near = cal.filter { dist(lat, lon, $0.lat, $0.lon) <= nearM }
        if near.isEmpty { return (g, 0) }
        if Set(near.map(\.level)).count >= 2 {
            let n = Double(near.count)
            let mx = near.map { Double($0.level) }.reduce(0, +) / n
            let my = near.map(\.dh).reduce(0, +) / n
            let sxx = near.map { pow(Double($0.level) - mx, 2) }.reduce(0, +)
            let sxy = near.map { (Double($0.level) - mx) * ($0.dh - my) }.reduce(0, +)
            let a = sxy / sxx
            if a >= aMin && a <= aMax { return (a, my - a * mx) }
        }
        var cnt: [Int: Int] = [:]
        for c in near { cnt[c.level, default: 0] += 1 }
        let lv = cnt.max { x, y in x.value != y.value ? x.value < y.value : abs(x.key) > abs(y.key) }!.key
        let same = near.filter { $0.level == lv }
        let m = same.map(\.dh).reduce(0, +) / Double(same.count)
        if lv != 0 {
            let a = m / Double(lv)
            if a >= aMin && a <= aMax { return (a, 0) }
        }
        return (g, m - g * Double(lv))
    }

    static func estimate(dh: Double, lat: Double, lon: Double, cal: [ParkCal]) -> Int {
        let (a, b) = model(lat: lat, lon: lon, cal: cal)
        let x = ((dh - b) / a + 0.5).rounded(.down)
        return max(levelMin, min(levelMax, Int(x)))
    }
}
