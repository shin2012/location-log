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
    let checkin: Bool?          // 이름이 스웜 체크인에서 옴
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
    let park: TimelinePark?     // 운전 끝 주차 층
    let floors: [TimelineFloor]?   // 머문 곳 안 층 구간 (층 이동이 있을 때만)
    let subs: [TimelineSub]?       // 층 구간이 없을 때 머문 곳 바로 아래 하위 항목 (워치 계단 층)

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

/// 운전 끝 주차 (서버 park). level: 지상1층=0, 지하1층=-1. est = 추정(사용자가 안 고침)
struct TimelinePark: Decodable, Hashable {
    let ts: Double
    let level: Int
    let label: String
    let est: Bool
}

/// 머문 곳 안 층 구간 (서버 floors.py). via = 이 층으로 온 방법
struct TimelineFloor: Decodable, Hashable, Identifiable {
    let start: Double
    let end: Double
    let level: Int
    let label: String
    let est: Bool
    let via: String?            // elevator | stairs | escalator
    let dh: Double
    let ap: String?
    let subs: [TimelineSub]?    // 이 층(폰으로 확인)에 폰을 두고 워치 계단으로 다녀온 층 — 시간순
    var id: Double { start }

    var viaLabel: String? {
        switch via {
        case "elevator": return "엘리베이터로 이동"
        case "stairs": return "계단으로 이동"
        case "escalator": return "에스컬레이터로 이동"
        default: return nil
        }
    }
}

/// 폰으로 확인된 항목 아래 작은 글씨 하위 항목 (서버 floors.segments subs)
/// kind: floor = 폰 두고 워치 계단으로 오른 층 · back = 폰 있는 층으로 돌아옴
struct TimelineSub: Decodable, Hashable, Identifiable {
    let kind: String
    let start: Double
    let end: Double
    let steps: Int?
    let level: Int?
    let label: String?
    let est: Bool?
    let dh: Double?
    var id: String { "\(kind)-\(Int(start))" }
}

struct FloorFixBody: Encodable {
    let ts: Double
    let lat: Double
    let lon: Double
    let dh: Double
    let level: Int?
    let ap: String?
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
    var lat: Double?
    var lon: Double?
}

struct ACPlaceNew: Encodable {
    let venueId: String
    let name: String
    let lat: Double
    let lon: Double
    var radius = 100
}

/// 장소 추가 후보 = 내가 체크인했던 포스퀘어 장소
struct ACVenue: Decodable, Identifiable, Hashable {
    let venueId: String
    let name: String
    let category: String?
    let lat: Double
    let lon: Double
    let n: Int
    let last: Double
    let distM: Int?
    let added: Bool
    var id: String { venueId }
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
