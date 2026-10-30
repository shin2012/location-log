import Foundation

/// 이 기기의 기록을 파일(Application Support/tracks.json)에 보관하고 서버로 올림.
/// 서버에 다 올라가고 끝난 기록은 목록에서 지움 → 앱이 꺼지거나 통신이 끊겨도 잃지 않음.
/// 토큰이 없으면 서버로 안 올리고 이 기기에만 계속 보관 (다른 사람 테스트용).
@MainActor
final class TrackStore: ObservableObject {
    @Published private(set) var tracks: [LocalTrack] = []
    @Published private(set) var lastSyncError: String?
    @Published private(set) var lastSyncAt: Date?

    private var syncing = false
    private var lastSave = Date.distantPast
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("tracks.json")
        if let d = try? Data(contentsOf: fileURL),
           let t = try? JSONDecoder().decode([LocalTrack].self, from: d) {
            tracks = t
        }
    }

    var active: LocalTrack? { tracks.first { $0.endedAt == nil } }
    private var activeIndex: Int? { tracks.firstIndex { $0.endedAt == nil } }
    private func index(_ cid: String) -> Int? { tracks.firstIndex { $0.clientId == cid } }
    var pendingPoints: Int { tracks.reduce(0) { $0 + $1.pendingCount } }

    // MARK: 기록

    func start(mode: TravelMode) {
        if activeIndex != nil { return }
        let now = Date()
        let t = LocalTrack(clientId: UUID().uuidString.lowercased(),
                           name: Fmt.recName(now),
                           startedAt: now.timeIntervalSince1970 * 1000,
                           endedAt: nil, mode: mode, serverId: nil, points: [],
                           uploadedSeq: -1, needsPatch: mode != .car, distanceM: 0, renamed: nil)
        tracks.append(t)
        save(force: true)
    }

    func append(_ p: TrackPoint, distanceAdd: Double) {
        guard let i = activeIndex else { return }
        tracks[i].points.append(p)
        tracks[i].distanceM += distanceAdd
        save()
    }

    func setMode(_ m: TravelMode) {
        guard let i = activeIndex, tracks[i].mode != m else { return }
        tracks[i].mode = m
        tracks[i].needsPatch = true
        save(force: true)
    }

    /// 끝난 기록의 이동 수단 바꾸기 (진행 중이면 setMode와 같음)
    func setMode(_ m: TravelMode, for cid: String) {
        guard let i = index(cid), tracks[i].mode != m else { return }
        tracks[i].mode = m
        tracks[i].needsPatch = true
        save(force: true)
    }

    /// 이 기기에서만 지움 (진행 중인 기록은 못 지움). 서버 삭제는 부르는 쪽에서
    func removeLocal(_ cid: String) {
        guard let i = index(cid), tracks[i].endedAt != nil else { return }
        tracks.remove(at: i)
        save(force: true)
    }

    func rename(_ cid: String, to name: String) {
        guard let i = index(cid) else { return }
        tracks[i].name = name
        tracks[i].renamed = true
        tracks[i].needsPatch = true
        save(force: true)
    }

    func track(_ cid: String) -> LocalTrack? { tracks.first { $0.clientId == cid } }

    /// 기록 끝. 점이 2개 미만이면 버림
    func finish() {
        guard let i = activeIndex else { return }
        if tracks[i].points.count < 2 {
            let sid = tracks[i].serverId
            tracks.remove(at: i)
            if let sid { Task { try? await API.delete(sid) } }
        } else {
            tracks[i].endedAt = (tracks[i].points.last?.ts) ?? Date().timeIntervalSince1970 * 1000
            tracks[i].needsPatch = true
        }
        save(force: true)
    }

    func save(force: Bool = false) {
        if !force && Date().timeIntervalSince(lastSave) < 10 { return }
        lastSave = Date()
        do {
            let d = try JSONEncoder().encode(tracks)
            try d.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            lastSyncError = "저장 실패: \(error.localizedDescription)"
        }
    }

    // MARK: 서버로 올리기

    func sync() async {
        guard !syncing, !tracks.isEmpty, !AppSettings.shared.token.isEmpty else { return }
        syncing = true
        defer { syncing = false }
        do {
            for cid in tracks.map(\.clientId) {
                try await syncTrack(cid)
            }
            lastSyncError = nil
            lastSyncAt = Date()
        } catch {
            lastSyncError = error.localizedDescription
        }
        save(force: true)
    }

    private func syncTrack(_ cid: String) async throws {
        guard let i0 = index(cid) else { return }
        if tracks[i0].serverId == nil {
            let t = tracks[i0]
            let s: ServerTrack = try await API.send("POST", "tracks",
                body: CreateTrackBody(clientId: t.clientId, name: t.name, startedAt: t.startedAt))
            guard let i = index(cid) else { return }
            tracks[i].serverId = s.id
        }
        // 점: 500개씩
        while let i = index(cid), let sid = tracks[i].serverId {
            let up = tracks[i].uploadedSeq
            let batch = Array(tracks[i].points.lazy.filter { $0.seq > up }.prefix(500))
            guard let lastSeq = batch.last?.seq else { break }
            let _: OKResponse = try await API.send("POST", "tracks/\(sid)/points", body: PointsBody(points: batch))
            guard let j = index(cid) else { return }
            tracks[j].uploadedSeq = max(tracks[j].uploadedSeq, lastSeq)
        }
        // 끝난 시각·이동 수단
        guard let i = index(cid), let sid = tracks[i].serverId else { return }
        if tracks[i].needsPatch {
            let t = tracks[i]
            _ = try await API.patch(sid, PatchBody(name: t.renamed == true ? t.name : nil,
                                                   endedAt: t.endedAt, mode: t.mode.rawValue))
            if let j = index(cid), tracks[j].mode == t.mode, tracks[j].endedAt == t.endedAt, tracks[j].name == t.name {
                tracks[j].needsPatch = false
            }
        }
        // 끝났고 다 올라갔으면 이 기기 목록에서 지움 (서버 목록에서 보임)
        if let j = index(cid), tracks[j].endedAt != nil, !tracks[j].needsPatch, tracks[j].pendingCount == 0 {
            tracks.remove(at: j)
        }
    }
}
