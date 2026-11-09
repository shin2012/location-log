import Foundation
import CoreLocation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct OKResponse: Decodable { let ok: Bool? }

struct CreateTrackBody: Encodable {
    let clientId: String
    let name: String
    let startedAt: Double
}

struct PointsBody: Encodable { let points: [TrackPoint] }

struct PatchBody: Encodable {
    var name: String?
    var endedAt: Double?
    var mode: String?
}

/// location.b-612.kr/app-api — 실라쥬 전용 FastAPI. Bearer 토큰.
enum API {
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static func send<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil,
                                   cellular: Bool = true) async throws -> T {
        let s = AppSettings.shared
        let base = s.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base.hasSuffix("/") ? base + path : base + "/" + path) else {
            throw APIError(message: "서버 주소가 잘못됨")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.allowsCellularAccess = cellular
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !s.token.isEmpty {
            req.setValue("Bearer \(s.token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try encoder.encode(body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "응답 없음") }
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = obj?["detail"] as? String
            throw APIError(message: "서버 오류 \(http.statusCode)" + (detail.map { ": \($0)" } ?? ""))
        }
        return try decoder.decode(T.self, from: data)
    }

    static func tracks() async throws -> [ServerTrack] { try await send("GET", "tracks") }
    static func track(_ id: Int) async throws -> ServerTrackDetail { try await send("GET", "tracks/\(id)") }
    static func patch(_ id: Int, _ body: PatchBody) async throws -> ServerTrack { try await send("PATCH", "tracks/\(id)", body: body) }
    static func delete(_ id: Int) async throws { let _: OKResponse = try await send("DELETE", "tracks/\(id)") }
    static func sendDaily(_ id: Int, _ on: Bool) async throws -> ServerTrack {
        try await send(on ? "POST" : "DELETE", "tracks/\(id)/send-daily")
    }
    // 하루 종일 기록
    static func days() async throws -> [ServerDay] { try await send("GET", "day") }
    static func day(_ date: String) async throws -> ServerDayDetail { try await send("GET", "day/\(date)") }
    static func deleteDay(_ date: String) async throws { let _: OKResponse = try await send("DELETE", "day/\(date)") }
    static func timeline(_ date: String) async throws -> TimelineDay { try await send("GET", "day/\(date)/timeline") }
    // 자동 체크인
    static func acPlaces() async throws -> [ACPlace] { try await send("GET", "autocheckin/places?all=1") }
    static func acPatch(_ venueId: String, _ body: ACPlacePatch) async throws -> ACPlace {
        try await send("PATCH", "autocheckin/places/\(venueId)", body: body)
    }
    static func acAdd(_ body: ACPlaceNew) async throws -> ACPlace { try await send("POST", "autocheckin/places", body: body) }
    static func acDelete(_ venueId: String) async throws { let _: OKResponse = try await send("DELETE", "autocheckin/places/\(venueId)") }
    static func acVenues(q: String, near: CLLocationCoordinate2D?) async throws -> [ACVenue] {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "limit", value: "40")]
        if !q.isEmpty { c.queryItems?.append(URLQueryItem(name: "q", value: q)) }
        if let n = near {
            c.queryItems? += [URLQueryItem(name: "lat", value: String(n.latitude)), URLQueryItem(name: "lon", value: String(n.longitude))]
        }
        let qs = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return try await send("GET", "autocheckin/venues?" + qs)
    }
    static func acEvents(days: Int = 7) async throws -> ACEvents { try await send("GET", "autocheckin/events?days=\(days)") }

    static func health() async throws -> Bool {
        let r: OKResponse = try await send("GET", "health")
        return r.ok == true
    }
}
