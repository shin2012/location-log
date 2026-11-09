import Foundation
import AVFoundation

/// CarPlay 연결 알아채기.
/// 1순위: 단축어 자동화 'CarPlay 연결 시/해제 시' → 앱 동작(CarPlayIntents.swift). 애플 공식 신호라 놓치지 않음.
///        한 번이라도 단축어로 받으면 그 뒤로는 단축어만 믿음 (아래 오디오 경로 판정은 끔).
/// 2순위(단축어 설정 전): 소리 출력 경로에 '차량 오디오(carAudio)'가 있으면 연결된 것.
/// 상태는 저장해 두어 앱이 다시 켜져도 같은 연결을 두 번 보내지 않는다.
@MainActor
final class CarPlayWatcher: ObservableObject {
    static let shared = CarPlayWatcher()

    @Published private(set) var connected = false
    @Published private(set) var since: Date?
    /// 연결(true)·해제(false)가 바뀔 때만
    var onChange: ((Bool) -> Void)?

    private static let stateKey = "carplay.connected"
    private static let viaKey = "carplay.viaShortcut"
    private var started = false
    /// 단축어로 받은 적 있음 → 오디오 경로 판정 안 씀
    @Published private(set) var viaShortcut = false

    private init() {
        connected = UserDefaults.standard.bool(forKey: Self.stateKey)
        viaShortcut = UserDefaults.standard.bool(forKey: Self.viaKey)
    }

    /// 단축어 동작에서
    func set(_ on: Bool) {
        if !viaShortcut {
            viaShortcut = true
            UserDefaults.standard.set(true, forKey: Self.viaKey)
        }
        update(on)
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    static func isCarRoute() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    func check() {
        guard !viaShortcut else { return }
        update(Self.isCarRoute())
    }

    private func update(_ on: Bool) {
        guard on != connected else { return }
        connected = on
        since = Date()
        UserDefaults.standard.set(on, forKey: Self.stateKey)
        onChange?(on)
    }
}

/// CarPlay 연결·해제를 서버로 (단축어 대신). 서버(location-api)가 swarm 지도 CarPlay API 로 넘김.
/// 통신이 안 되면 쌓아 두었다가 다음 업로드 때 다시 보냄.
@MainActor
final class CarPlayEvents: ObservableObject {
    static let shared = CarPlayEvents()

    struct Event: Codable, Equatable {
        var event: String      // car_start | car_end
        var ts: Double         // epoch ms
        var lat: Double?
        var lng: Double?
    }

    @Published private(set) var pending: [Event] = []
    @Published private(set) var lastSentAt: Date?
    @Published private(set) var lastError: String?

    private static let key = "carplay.pending"
    private var sending = false

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let v = try? JSONDecoder().decode([Event].self, from: d) {
            pending = v
        }
    }

    func add(_ on: Bool, at: Date, lat: Double?, lng: Double?) {
        pending.append(Event(event: on ? "car_start" : "car_end", ts: (at.timeIntervalSince1970 * 1000).rounded(), lat: lat, lng: lng))
        if pending.count > 200 { pending.removeFirst(pending.count - 200) }
        save()
        Task { await flush() }
    }

    func flush() async {
        guard !sending, !pending.isEmpty, !AppSettings.shared.token.isEmpty else { return }
        sending = true
        defer { sending = false; save() }
        while let e = pending.first {
            do {
                let _: OKResponse = try await API.send("POST", "carplay", body: e)
                pending.removeFirst()
                lastSentAt = Date()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(pending) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}
