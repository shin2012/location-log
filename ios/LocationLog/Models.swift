import Foundation
import CoreLocation

/// 이동 수단 — 서버 track.mode 값과 같음
enum TravelMode: String, CaseIterable, Codable, Identifiable {
    case car, walk, bicycle, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .car: return "자동차"
        case .walk: return "걷기"
        case .bicycle: return "자전거"
        case .other: return "기타"
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
    /// brk 표시된 곳에서 선을 끊어 여러 조각으로 나눔
    static func segments(_ pts: [TrackPoint]) -> [[CLLocationCoordinate2D]] {
        var out: [[CLLocationCoordinate2D]] = []
        var cur: [CLLocationCoordinate2D] = []
        for p in pts {
            if p.brk == true, !cur.isEmpty {
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
