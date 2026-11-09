import Foundation
import CoreLocation
import UIKit

/// 자동 체크인 — 서버에 등록된 장소(집·회사 등) 반경에 들어가고 나가는 것을 감지해 그대로 서버로 보냄.
/// IFTTT 위치 트리거 → 구글 캘린더 → 람다 경로를 대신한다.
/// 걸러내기(3분 머묾 확인, 나간 뒤 15분 안 재진입 무시)는 서버(location-api)가 함 —
/// 앱은 백그라운드에서 몇 분씩 기다릴 수 없어서 감지 시각만 정확히 남긴다.
/// 장소 목록은 서버(auto_place)에서 받아 와 앱 업데이트 없이 바꿀 수 있음.
@MainActor
final class AutoCheckin: ObservableObject {
    static let shared = AutoCheckin()
    static let prefix = "auto."

    struct Place: Codable, Equatable, Identifiable {
        var venueId: String
        var name: String
        var lat: Double
        var lon: Double
        var radius: Double
        var id: String { venueId }
    }

    struct Event: Codable, Equatable {
        var clientId: String
        var venueId: String
        var kind: String       // enter | exit
        var ts: Double         // epoch ms
        var lat: Double?
        var lon: Double?
        var acc: Double?
    }

    struct Log: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var kind: String
        var at: Date
    }

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            onChange?()
        }
    }
    @Published private(set) var places: [Place] = []
    @Published private(set) var pending: [Event] = []
    @Published private(set) var recent: [Log] = []
    @Published private(set) var lastError: String?
    @Published private(set) var placesAt: Date?

    /// 장소·켜기가 바뀌면 감시 영역 다시 맞추기 (DayLogger 가 연결)
    var onChange: (() -> Void)?

    private static let enabledKey = "auto.enabled"
    private static let placesKey = "auto.places"
    private static let pendingKey = "auto.pending"
    private static let recentKey = "auto.recent"
    private var sending = false

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: Self.enabledKey) as? Bool ?? true
        if let x = d.data(forKey: Self.placesKey), let v = try? JSONDecoder().decode([Place].self, from: x) { places = v }
        if let x = d.data(forKey: Self.pendingKey), let v = try? JSONDecoder().decode([Event].self, from: x) { pending = v }
        if let x = d.data(forKey: Self.recentKey), let v = try? JSONDecoder().decode([Log].self, from: x) { recent = v }
    }

    func name(_ venueId: String) -> String { places.first { $0.venueId == venueId }?.name ?? venueId }

    // MARK: 감시 영역

    /// 켜져 있으면 장소마다 원형 영역 감시, 꺼져 있으면 모두 해제. ('day.stay' 같은 다른 영역은 건드리지 않음)
    func apply(_ manager: CLLocationManager) {
        let want = enabled ? places : []
        let ids = Set(want.map { Self.prefix + $0.venueId })
        for r in manager.monitoredRegions where r.identifier.hasPrefix(Self.prefix) && !ids.contains(r.identifier) {
            manager.stopMonitoring(for: r)
        }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        for p in want {
            let id = Self.prefix + p.venueId
            let radius = min(p.radius, manager.maximumRegionMonitoringDistance)
            if let r = manager.monitoredRegions.first(where: { $0.identifier == id }) as? CLCircularRegion,
               abs(r.center.latitude - p.lat) < 1e-6, abs(r.center.longitude - p.lon) < 1e-6, abs(r.radius - radius) < 1 {
                continue
            }
            let reg = CLCircularRegion(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), radius: radius, identifier: id)
            reg.notifyOnEntry = true
            reg.notifyOnExit = true
            manager.startMonitoring(for: reg)
        }
    }

    /// CLLocationManager 영역 알림 → 대기열에 넣고 바로 보냄
    func regionEvent(_ identifier: String, enter: Bool, location: CLLocation?) {
        guard enabled, identifier.hasPrefix(Self.prefix) else { return }
        let vid = String(identifier.dropFirst(Self.prefix.count))
        let now = Date()
        // 영역 알림과 함께 온 위치가 오래됐으면 버림 (시각은 알림 받은 때)
        let loc = location.flatMap { now.timeIntervalSince($0.timestamp) < 120 ? $0 : nil }
        pending.append(Event(clientId: UUID().uuidString, venueId: vid, kind: enter ? "enter" : "exit",
                             ts: (now.timeIntervalSince1970 * 1000).rounded(),
                             lat: loc?.coordinate.latitude, lon: loc?.coordinate.longitude, acc: loc?.horizontalAccuracy))
        if pending.count > 300 { pending.removeFirst(pending.count - 300) }
        recent.insert(Log(id: UUID().uuidString, name: name(vid), kind: enter ? "enter" : "exit", at: now), at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
        save()
        Task { await flush() }
    }

    // MARK: 서버

    /// 장소 목록 받아 오기 (6시간마다, force 면 바로)
    func refreshPlaces(force: Bool = false) async {
        guard !AppSettings.shared.token.isEmpty else { return }
        if !force, let t = placesAt, Date().timeIntervalSince(t) < 6 * 3600 { return }
        do {
            let v: [Place] = try await API.send("GET", "autocheckin/places")
            placesAt = Date()
            if v != places {
                places = v
                save()
                onChange?()
            }
        } catch {
            lastError = "장소 목록: " + error.localizedDescription
        }
    }

    func flush() async {
        guard !sending, !pending.isEmpty, !AppSettings.shared.token.isEmpty else { return }
        sending = true
        // 영역 알림으로 백그라운드에서 깨어난 경우 몇 초 더 받아서 보내기
        let bg = UIApplication.shared.beginBackgroundTask(withName: "autocheckin") {}
        defer {
            sending = false
            save()
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        while let e = pending.first {
            do {
                let _: OKResponse = try await API.send("POST", "autocheckin/event", body: e)
                pending.removeFirst()
                lastError = nil
            } catch let err as APIError where err.message.contains("404") {
                pending.removeFirst()      // 서버에서 지운 장소 — 버림
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }

    private func save() {
        let d = UserDefaults.standard, enc = JSONEncoder()
        if let x = try? enc.encode(places) { d.set(x, forKey: Self.placesKey) }
        if let x = try? enc.encode(pending) { d.set(x, forKey: Self.pendingKey) }
        if let x = try? enc.encode(recent) { d.set(x, forKey: Self.recentKey) }
    }
}
