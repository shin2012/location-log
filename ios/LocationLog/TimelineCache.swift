import Foundation

/// 타임라인 기기 저장본: 날짜별 서버 응답 원본 (Application Support/timeline/YYYY-MM-DD.json).
/// 인터넷이 없거나 서버에 못 붙을 때 마지막으로 받은 타임라인을 보여 줌. 60일 지난 건 지움.
enum TimelineCache {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("timeline", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save(_ day: String, _ data: Data) {
        try? data.write(to: dir.appendingPathComponent("\(day).json"), options: .atomic)
        prune()
    }

    /// (내용, 받은 시각)
    static func load(_ day: String) -> (TimelineDay, Date)? {
        let u = dir.appendingPathComponent("\(day).json")
        guard let d = try? Data(contentsOf: u), let t = try? API.decode(TimelineDay.self, d) else { return nil }
        let at = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? Date()
        return (t, at)
    }

    private static func prune() {
        let cut = DayLogStore.dayKey((Date().timeIntervalSince1970 - 60 * 86400) * 1000)
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where n.hasSuffix(".json") && String(n.dropLast(5)) < cut {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }
}

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
