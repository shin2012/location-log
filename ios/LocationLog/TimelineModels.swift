import Foundation
import CoreLocation

/// GET /api/day/{date}/timeline
struct TimelineDay: Decodable {
    let date: String
    let items: [TimelineItem]
    let summary: TimelineSummary
}

struct TimelineSummary: Decodable {
    let km: Double
    let steps: Int
    let driveMin: Int
    let visits: Int
}

struct TimelineItem: Decodable, Identifiable, Hashable {
    let kind: String            // visit | move
    let start: Double           // epoch ms
    let end: Double
    // 머문 곳
    let lat: Double?
    let lon: Double?
    let name: String?
    let open: Bool?
    let minutes: Int?
    // 이동
    let km: Double?
    let mode: String?           // car | walk | bike | unknown
    let drove: Bool?            // CarPlay 연결 = 내가 운전
    let steps: Int?
    let est: Bool?              // 터널 센서 추정 포함
    let path: [[Double]]?

    var id: String { "\(kind)-\(Int(start))" }
    var isVisit: Bool { kind == "visit" }
    var coords: [CLLocationCoordinate2D] { (path ?? []).compactMap { $0.count == 2 ? .init(latitude: $0[0], longitude: $0[1]) : nil } }
    var center: CLLocationCoordinate2D? { lat.flatMap { la in lon.map { .init(latitude: la, longitude: $0) } } }
    var durationMs: Double { end - start }

    /// 이동 이름·아이콘: CarPlay 가 있으면 운전, 차인데 없으면 차량 이동
    var moveLabel: String {
        switch mode {
        case "car": return drove == true ? "운전" : "차량 이동"
        case "walk": return "도보"
        case "bike": return "자전거"
        default: return "이동"
        }
    }
    var moveSymbol: String {
        switch mode {
        case "car": return drove == true ? "steeringwheel" : "car.fill"
        case "walk": return "figure.walk"
        case "bike": return "bicycle"
        default: return "arrow.triangle.swap"
        }
    }
}

/// 자동 체크인 장소 (GET autocheckin/places?all=1)
struct ACPlace: Codable, Identifiable, Hashable {
    let venueId: String
    var name: String
    let lat: Double
    let lon: Double
    var radius: Int
    var enabled: Bool?
    var id: String { venueId }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct ACPlacePatch: Encodable {
    var radius: Int?
    var enabled: Bool?
    var name: String?
}

/// GET autocheckin/events
struct ACEvents: Decodable {
    let write: Bool
    let events: [ACEvent]
}

struct ACEvent: Decodable, Identifiable, Hashable {
    let id: Int
    let venueId: String
    let name: String?
    let kind: String            // enter | exit
    let at: Double              // epoch ms
    let status: String          // pending | confirmed | ignored | sent | failed
    let note: String?
    let fsqId: String?

    var statusText: String {
        switch status {
        case "pending": return "확인 중"
        case "confirmed": return kind == "enter" ? "체크인 확정" : "나감 확정"
        case "sent": return "체크인 저장됨"
        case "ignored": return "무시"
        case "failed": return "저장 실패"
        default: return status
        }
    }
}
