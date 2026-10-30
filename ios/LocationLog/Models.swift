import Foundation
import CoreLocation

/// 이동 수단 — 서버 track.mode 값과 같음
enum TravelMode: String, CaseIterable, Codable, Identifiable {
    case car, walk, bicycle, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .car: return "차량"
        case .walk: return "도보"
        case .bicycle: return "자전거"
        case .other: return "기타"
        }
    }

    var emoji: String {
        switch self {
        case .car: return "🚗"
        case .walk: return "🚶"
        case .bicycle: return "🚲"
        case .other: return "📍"
        }
    }

    var symbol: String {
        switch self {
        case .car: return "car.fill"
        case .walk: return "figure.walk"
        case .bicycle: return "bicycle"
        case .other: return "ellipsis.circle"
        }
    }

    var activityType: CLActivityType {
        switch self {
        case .car: return .automotiveNavigation
        case .walk, .bicycle: return .fitness
        case .other: return .other
        }
    }
}

/// 점 하나 — 서버 Pt 모델과 같은 이름 (brk는 앱 안에서만 씀, 서버는 무시)
struct TrackPoint: Codable, Hashable {
    var seq: Int
    var ts: Double          // epoch ms
    var lat: Double
    var lon: Double
    var alt: Double?
    var acc: Double?
    var spd: Double?
    var hdg: Double?
    var src: String
    var brk: Bool?          // 순간 이동(비행 등) 뒤 첫 점: 앞 점과 선을 잇지 않음

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
}

/// 이 기기에서 기록했지만 아직 서버에 다 올리지 못한 기록 (진행 중 포함)
struct LocalTrack: Codable, Identifiable {
    var clientId: String
    var name: String
    var startedAt: Double   // epoch ms
    var endedAt: Double?
    var mode: TravelMode
    var serverId: Int?
    var points: [TrackPoint]
    var uploadedSeq: Int    // 서버에 올라간 마지막 seq
    var needsPatch: Bool    // 끝난 시각·이동 수단을 서버에 아직 반영 안 함
    var distanceM: Double
    var renamed: Bool?      // 이 기기에서 이름을 바꿈 → 마무리할 때 서버에도 이름 반영

    var id: String { clientId }
    var nextSeq: Int { (points.last?.seq ?? -1) + 1 }
    var pendingCount: Int { points.reduce(0) { $0 + ($1.seq > uploadedSeq ? 1 : 0) } }
}

/// 서버 기록 (GET /api/tracks)
struct ServerTrack: Codable, Identifiable, Hashable {
    let id: Int
    let clientId: String
    var name: String
    let startedAt: Double?
    var endedAt: Double?
    let distanceM: Double?
    let nPoints: Int?
    let nEst: Int?
    var sentDailyAt: Double?
    var mode: String?
}

/// 서버 기록 + 점 (GET /api/tracks/{id})
struct ServerTrackDetail: Codable {
    let id: Int
    let clientId: String
    var name: String
    let startedAt: Double?
    var endedAt: Double?
    let distanceM: Double?
    let nPoints: Int?
    let nEst: Int?
    var sentDailyAt: Double?
    var mode: String?
    let points: [TrackPoint]

    var track: ServerTrack {
        ServerTrack(id: id, clientId: clientId, name: name, startedAt: startedAt, endedAt: endedAt,
                    distanceM: distanceM, nPoints: nPoints, nEst: nEst, sentDailyAt: sentDailyAt, mode: mode)
    }
}

enum TrackGeometry {
    /// 순간 이동(비행·오래 끊김 뒤 다른 곳): 선을 잇지 않음 — 웹 isBreak와 같음
    static func isBreak(_ q: TrackPoint?, _ p: TrackPoint) -> Bool {
        if p.brk == true { return true }
        guard let q else { return false }
        let dt = (p.ts - q.ts) / 1000
        return dt > 0 && p.location.distance(from: q.location) / dt > 120
    }

    /// 끊기는 곳에서 선을 나눔
    static func segments(_ pts: [TrackPoint]) -> [[CLLocationCoordinate2D]] {
        var out: [[CLLocationCoordinate2D]] = []
        var cur: [CLLocationCoordinate2D] = []
        var prev: TrackPoint?
        for p in pts {
            defer { prev = p }
            if isBreak(prev, p), !cur.isEmpty {
                out.append(cur)
                cur = []
            }
            cur.append(p.coordinate)
        }
        out.append(cur)
        return out.filter { $0.count > 1 }
    }
}

enum Fmt {
    private static let week = Array("일월화수목금토")

    private static func comps(_ ms: Double) -> DateComponents {
        Calendar.current.dateComponents([.month, .day, .hour, .minute, .second, .weekday],
                                        from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// 14:03:09
    static func hms(_ ms: Double) -> String {
        let c = comps(ms)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// 14:03
    static func hm(_ ms: Double) -> String { String(hms(ms).prefix(5)) }

    /// 10월 30일 (목)
    static func dateKo(_ ms: Double) -> String {
        let c = comps(ms)
        return "\(c.month ?? 0)월 \(c.day ?? 0)일 (\(week[((c.weekday ?? 1) - 1) % 7]))"
    }

    /// 01:02:03
    static func clock(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    /// 5분 / 1시간 20분
    static func durKo(_ ms: Double) -> String {
        let m = Int((ms / 60000).rounded())
        return m < 60 ? "\(m)분" : "\(m / 60)시간 \(m % 60)분"
    }

    /// 10월 30일 14:03 기록
    static func recName(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: d)
        return String(format: "%d월 %d일 %02d:%02d 기록", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 북 / 북동 / … (8방위)
    static func dirName(_ h: Double?) -> String {
        guard let h else { return "–" }
        let n = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return ["북", "북동", "동", "남동", "남", "남서", "서", "북서"][Int((n / 45).rounded()) % 8]
    }

    static func distance(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f km", m / 1000) : String(format: "%.0f m", m)
    }

    static func duration(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func speed(_ mps: Double?) -> String {
        guard let v = mps, v >= 0 else { return "-" }
        return String(format: "%.0f km/h", v * 3.6)
    }

    static func date(_ ms: Double?) -> String {
        guard let ms else { return "-" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy-MM-dd (E) HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    static func defaultName(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
