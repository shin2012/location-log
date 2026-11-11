import Foundation

/// 원본 보관함: 종류별·날짜별 JSONL (Application Support/archive/<종류>/YYYY-MM-DD.jsonl), 지우지 않음.
/// 다른 앱(iOS 동작 기록 7일·건강 앱 등)에서 원본이 없어져도 시야쥬 기록은 그대로 남게 — 받은 순간 여기 먼저 씀.
/// 서버로는 여기서 줄 수 커서로 올림 (DayLogStore 와 같은 방식). 통신이 안 되면 다음에 이어서.
@MainActor
final class ArchiveLog<T: Codable> {
    let kind: String
    private let dir: URL
    private let tsOf: (T) -> Double          // epoch ms → 날짜 정하기
    private var counts: [String: Int]
    private var uploaded: [String: Int]
    private var uploading = false
    private var countsKey: String { "archive.\(kind).counts" }
    private var uploadedKey: String { "archive.\(kind).uploaded" }

    init(_ kind: String, ts: @escaping (T) -> Double) {
        self.kind = kind
        tsOf = ts
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("archive/\(kind)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        counts = (UserDefaults.standard.dictionary(forKey: "archive.\(kind).counts") as? [String: Int]) ?? [:]
        uploaded = (UserDefaults.standard.dictionary(forKey: "archive.\(kind).uploaded") as? [String: Int]) ?? [:]
    }

    var pending: Int { counts.reduce(0) { $0 + max(0, $1.value - (uploaded[$1.key] ?? 0)) } }
    var total: Int { counts.values.reduce(0, +) }

    func append(_ items: [T]) {
        guard !items.isEmpty else { return }
        let enc = JSONEncoder()
        var byDay: [String: Data] = [:]
        var n: [String: Int] = [:]
        for x in items {
            guard var line = try? enc.encode(x) else { continue }
            line.append(0x0A)
            let d = DayLogStore.dayKey(tsOf(x))
            byDay[d, default: Data()].append(line)
            n[d, default: 0] += 1
        }
        for (d, data) in byDay {
            let url = dir.appendingPathComponent("\(d).jsonl")
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil,
                                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                }
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
                counts[d, default: 0] += n[d] ?? 0
            } catch {}
        }
        save()
    }

    func days() -> [String] { counts.keys.sorted() }

    func items(_ day: String) -> [T] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(day).jsonl")) else { return [] }
        let dec = JSONDecoder()
        return d.split(separator: 0x0A).compactMap { try? dec.decode(T.self, from: Data($0)) }
    }

    /// 안 올린 줄부터 묶어 send. 실패하면 거기서 멈추고 다음에 이어서
    func upload(batch: Int = 1000, _ send: ([T]) async throws -> Void) async throws {
        guard !uploading else { return }
        uploading = true
        defer { uploading = false; save() }
        for day in counts.keys.sorted() {
            let total = counts[day] ?? 0
            var done = uploaded[day] ?? 0
            guard done < total else { continue }
            let v = items(day)
            var i = min(done, v.count)
            while i < v.count {
                let b = Array(v[i..<min(v.count, i + batch)])
                try await send(b)
                i += b.count
                done = i
                uploaded[day] = done
            }
            if v.count < total { counts[day] = v.count }   // 깨진 줄이 있었으면 맞춤
        }
    }

    /// 서버로 안 보내는 보관 전용(사용자 고침 기록 등): 올린 것으로 표시
    func markAllUploaded() { uploaded = counts; save() }

    private func save() {
        UserDefaults.standard.set(counts, forKey: countsKey)
        UserDefaults.standard.set(uploaded, forKey: uploadedKey)
    }
}

/// 사용자가 고친 기록 (주차 층·머문 곳 층) — 보관 전용
struct EditRecord: Codable {
    let at: Double          // 고친 시각 epoch ms
    let kind: String        // park | floor
    let ts: Double          // 대상(주차·층 구간) 시각
    let level: Int?         // nil = 고친 것 취소
}

@MainActor
enum Archives {
    static let acts = ArchiveLog<MotionHistory.ActItem>("act") { $0.ts }
    static let steps = ArchiveLog<MotionHistory.StepItem>("step") { $0.ts }
    static let health = ArchiveLog<HealthHistory.Item>("health") { $0.kind == HealthHistory.deletedKind ? $0.end : $0.start }
    static let wifi = ArchiveLog<WifiLog.Ev>("wifi") { $0.ts }
    static let carplay = ArchiveLog<CarPlayEvents.Event>("carplay") { $0.ts }
    static let park = ArchiveLog<Parking.Post>("park") { $0.ts }
    static let edits = ArchiveLog<EditRecord>("edit") { $0.at }

    /// 1.8 처음 실행 한 번: iOS·건강 앱이 아직 가진 지난 기록을 보관함에 다시 채우고, 이 기기 보관을 무제한으로
    /// (사용자 결정 2026-11-11: 수집한 원본은 날짜별로 전부 앱 안에 보관). 서버는 같은 시각 덮어쓰기라 다시 올라가도 안전.
    static func migrateOnce() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: "archive.v1") else { return }
        ud.set(true, forKey: "archive.v1")
        let back = Date().timeIntervalSince1970 - 7 * 86400 + 1800        // iOS 동작·걸음 기록은 7일
        ud.set(back, forKey: "motion.actCursor")
        ud.removeObject(forKey: "motion.actLast")
        ud.set((back / 60).rounded(.down) * 60, forKey: "motion.stepCursor")
        HealthHistory.resetForArchive(days: 30)
        var p = DaySettings.shared.prefs
        if p.keepDays != 0 { p.keepDays = 0; DaySettings.shared.prefs = p }
    }
}
