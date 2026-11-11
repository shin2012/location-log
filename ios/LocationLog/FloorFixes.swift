import Foundation

/// 층 고침 보낼 목록: 통신이 안 되면 쌓아 두었다가 다음 업로드 때 (주차 고침과 같은 방식)
@MainActor
final class FloorFixes {
    static let shared = FloorFixes()
    private static let key = "floor.pending"
    private(set) var pending: [FloorFixBody] = []
    private var sending = false

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let v = try? JSONDecoder().decode([FloorFixBody].self, from: d) { pending = v }
    }

    /// 넣고 바로 보내 봄. 보냈으면 true
    @discardableResult
    func add(_ f: FloorFixBody) async -> Bool {
        Archives.edits.append([EditRecord(at: (Date().timeIntervalSince1970 * 1000).rounded(), kind: "floor", ts: f.ts, level: f.level,
                                          lat: f.lat, lon: f.lon, dh: f.dh, ap: f.ap)])
        Archives.edits.markAllUploaded()
        pending.removeAll { abs($0.ts - f.ts) < 2 }
        pending.append(f)
        save()
        await flush()
        return !pending.contains { abs($0.ts - f.ts) < 2 }
    }

    func flush() async {
        guard !sending, !pending.isEmpty, !AppSettings.shared.token.isEmpty else { return }
        sending = true
        defer { sending = false; save() }
        while let f = pending.first {
            do {
                let _: OKResponse = try await API.send("PUT", "floor", body: f)
                pending.removeFirst()
            } catch { return }
        }
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: Self.key) }
}
