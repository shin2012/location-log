import Foundation
import Network
import NetworkExtension

/// 연결된 공유기 고유번호(BSSID) 기록 — 층 판정 보조 (같은 이름의 Wi-Fi 가 여러 대여도 공유기마다 다름).
/// iOS 는 주변 Wi-Fi 신호 세기를 앱에 주지 않음 → 지금 연결된 것만. 'Wi-Fi 정보 접근' 권한 + 위치 권한 필요.
/// 바뀔 때만 저장: 네트워크 경로가 바뀔 때 + 기압이 저장될 때(최소 1분 간격) 확인. 앱이 깨어 있는 동안만.
@MainActor
final class WifiLog: ObservableObject {
    static let shared = WifiLog()

    struct Ev: Codable, Equatable {
        let ts: Double          // epoch ms
        let bssid: String?      // nil = Wi-Fi 연결 없음
        let ssid: String?
    }

    @Published private(set) var current: Ev?
    @Published private(set) var lastError: String?

    private var monitor: NWPathMonitor?
    private var lastCheck = Date.distantPast
    private var checking = false
    private var sending = false
    private static let pendingKey = "wifi.pending", currentKey = "wifi.current"

    private init() {
        let ud = UserDefaults.standard
        // 1.7 까지 보내기 대기 목록 → 보관함으로 옮김
        if let d = ud.data(forKey: Self.pendingKey), let v = try? JSONDecoder().decode([Ev].self, from: d), !v.isEmpty {
            Archives.wifi.append(v)
        }
        ud.removeObject(forKey: Self.pendingKey)
        if let d = ud.data(forKey: Self.currentKey), let v = try? JSONDecoder().decode(Ev.self, from: d) { current = v }
    }

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { _ in
            Task { @MainActor in WifiLog.shared.check(force: true) }
        }
        m.start(queue: .main)
        monitor = m
        check(force: true)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// 최소 1분 간격 (force = 네트워크가 바뀜)
    func check(force: Bool = false) {
        guard monitor != nil, !checking, force || Date().timeIntervalSince(lastCheck) >= 60 else { return }
        checking = true
        lastCheck = Date()
        NEHotspotNetwork.fetchCurrent { net in
            let b = net?.bssid.lowercased(), s = net?.ssid
            Task { @MainActor in WifiLog.shared.got(bssid: b, ssid: s) }
        }
    }

    private func got(bssid: String?, ssid: String?) {
        checking = false
        let b = (bssid?.isEmpty == false) ? bssid : nil
        if let c = current, c.bssid == b { return }
        let e = Ev(ts: (Date().timeIntervalSince1970 * 1000).rounded(), bssid: b, ssid: b == nil ? nil : ssid)
        current = e
        Archives.wifi.append([e])     // 보관함(지우지 않음) → 업로드 때 서버로
        save()
    }

    struct Body: Encodable { let events: [Ev] }

    func upload(wifiOnly: Bool) async {
        guard !sending, Archives.wifi.pending > 0, !AppSettings.shared.token.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            let cellular = !wifiOnly
            try await Archives.wifi.upload { b in
                let _: OKResponse = try await API.send("POST", "day/wifi", body: Body(events: b), cellular: cellular)
            }
            lastError = nil
        } catch {
            lastError = "공유기: " + error.localizedDescription
        }
    }

    private func save() {
        let ud = UserDefaults.standard
        ud.set(current.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.currentKey)
    }
}
