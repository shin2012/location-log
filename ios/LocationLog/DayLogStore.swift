import Foundation

/// 하루 종일 기록 저장소: Application Support/day/YYYY-MM-DD.jsonl (점 한 줄씩 덧붙임 → 매번 전체를 다시 쓰지 않음)
/// + day/meta.json (날짜별 점 수·올린 수, 머문 곳). 서버에는 묶어서 올림.
@MainActor
final class DayLogStore: ObservableObject {
    struct Meta: Codable {
        var counts: [String: Int] = [:]      // 날짜 → 파일 줄 수
        var uploaded: [String: Int] = [:]    // 날짜 → 서버에 올린 줄 수
        var visits: [DayVisitRec] = []       // 최근 머문 곳 (보관 기간만큼)
        var pendingVisits: [Double] = []     // 서버에 아직 안 올린 머문 곳 (arrive)
    }

    @Published private(set) var meta = Meta()
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastError: String?

    private let dir: URL
    private var metaDirty = false
    private var lastMetaSave = Date.distantPast
    private var uploading = false

    static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ ms: Double) -> String { dayFmt.string(from: Date(timeIntervalSince1970: ms / 1000)) }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("day", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        if let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
           let m = try? JSONDecoder().decode(Meta.self, from: d) {
            meta = m
        }
    }

    var pendingCount: Int {
        meta.counts.reduce(0) { $0 + max(0, $1.value - (meta.uploaded[$1.key] ?? 0)) } + meta.pendingVisits.count
    }

    func count(_ day: String) -> Int { meta.counts[day] ?? 0 }

    // MARK: 쓰기

    func append(_ p: DayPoint) {
        let day = Self.dayKey(p.ts)
        let url = file(day)
        guard var line = try? JSONEncoder().encode(p) else { return }
        line.append(0x0A)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
            meta.counts[day, default: 0] += 1
            saveMeta()
        } catch {
            lastError = "저장 실패: \(error.localizedDescription)"
        }
    }

    func arrived(_ v: DayVisitRec) {
        meta.visits.append(v)
        markVisit(v.arrive)
        saveMeta(force: true)
    }

    func departed(_ v: DayVisitRec) {
        if let i = meta.visits.lastIndex(where: { $0.arrive == v.arrive }) { meta.visits[i] = v } else { meta.visits.append(v) }
        markVisit(v.arrive)
        saveMeta(force: true)
    }

    private func markVisit(_ arrive: Double) {
        if !meta.pendingVisits.contains(arrive) { meta.pendingVisits.append(arrive) }
    }

    func saveMeta(force: Bool = false) {
        metaDirty = true
        if !force && Date().timeIntervalSince(lastMetaSave) < 30 { return }
        lastMetaSave = Date()
        metaDirty = false
        if let d = try? JSONEncoder().encode(meta) {
            try? d.write(to: dir.appendingPathComponent("meta.json"),
                         options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func flush() { if metaDirty { saveMeta(force: true) } }

    // MARK: 읽기

    private func file(_ day: String) -> URL { dir.appendingPathComponent("\(day).jsonl") }

    /// 이 기기에 있는 날짜 (최근 먼저)
    func days() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }.sorted(by: >)
    }

    /// sorted = false 면 파일에 쓴 순서 그대로 (올린 수 세기용)
    func points(_ day: String, sorted: Bool = true) -> [DayPoint] {
        guard let d = try? Data(contentsOf: file(day)) else { return [] }
        let dec = JSONDecoder()
        let pts = d.split(separator: 0x0A).compactMap { try? dec.decode(DayPoint.self, from: Data($0)) }
        return sorted ? pts.sorted { $0.ts < $1.ts } : pts
    }

    func visits(_ day: String) -> [DayVisitRec] {
        meta.visits.filter { v in
            Self.dayKey(v.arrive) == day || v.depart.map { Self.dayKey($0) == day } == true
                || (v.depart.map { Self.dayKey(v.arrive) < day && Self.dayKey($0) > day } ?? false)
        }
    }

    func delete(_ day: String) {
        try? FileManager.default.removeItem(at: file(day))
        meta.counts[day] = nil
        meta.uploaded[day] = nil
        meta.visits.removeAll { Self.dayKey($0.arrive) == day }
        saveMeta(force: true)
    }

    /// 보관 기간 지난 날짜 지움 (서버에 다 올라간 것만. 토큰 없으면 기기만 쓰므로 기간만 봄)
    func prune(keepDays: Int) {
        guard keepDays > 0 else { return }   // 0 = 무제한
        let cut = Self.dayKey((Date().timeIntervalSince1970 - Double(keepDays) * 86400) * 1000)
        let local = AppSettings.shared.token.isEmpty
        for day in days() where day < cut {
            if local || (meta.uploaded[day] ?? 0) >= (meta.counts[day] ?? 0) { delete(day) }
        }
        meta.visits.removeAll { Self.dayKey($0.arrive) < cut && !meta.pendingVisits.contains($0.arrive) }
        saveMeta(force: true)
    }

    // MARK: 서버로 올리기 (묶어서)

    func upload(wifiOnly: Bool) async {
        guard !uploading, !AppSettings.shared.token.isEmpty, pendingCount > 0 else { return }
        uploading = true
        defer { uploading = false; saveMeta(force: true) }
        do {
            for day in meta.counts.keys.sorted() {
                let total = meta.counts[day] ?? 0
                var done = meta.uploaded[day] ?? 0
                guard done < total else { continue }
                let pts = points(day, sorted: false)   // 쓴 순서 그대로 → 올린 줄 수 다음부터
                var i = min(done, pts.count)
                while i < pts.count {
                    let batch = Array(pts[i..<min(pts.count, i + 1000)])
                    let _: OKResponse = try await API.send("POST", "day/points", body: DayPointsBody(points: batch),
                                                           cellular: !wifiOnly)
                    i += batch.count
                    done = i
                    meta.uploaded[day] = done
                }
                if pts.count < total { meta.counts[day] = pts.count }   // 깨진 줄이 있었으면 맞춤
            }
            let pv = meta.pendingVisits
            let vs = meta.visits.filter { pv.contains($0.arrive) }
            if !vs.isEmpty {
                let _: OKResponse = try await API.send("POST", "day/visits", body: DayVisitsBody(visits: vs), cellular: !wifiOnly)
            }
            meta.pendingVisits.removeAll { pv.contains($0) }
            lastUploadAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct DayPointsBody: Encodable { let points: [DayPoint] }
struct DayVisitsBody: Encodable { let visits: [DayVisitRec] }

/// GET /api/day
struct ServerDay: Codable, Hashable {
    let date: String
    let nPoints: Int
}

/// GET /api/day/{date}
struct ServerDayDetail: Codable {
    let date: String
    let points: [DayPoint]
    let visits: [DayVisitRec]
}
