import SwiftUI
import CoreLocation

/// 설정 목록의 한 줄 — 서버 기록이든 이 기기 기록이든 같은 모양
struct TrackItem: Identifiable {
    let clientId: String
    let serverId: Int?
    let name: String
    let startedAt: Double
    let endedAt: Double?
    let distanceM: Double
    let nPoints: Int
    let nEst: Int
    let sentDailyAt: Double?
    let mode: TravelMode
    let recording: Bool
    let localOnly: Bool     // 서버 목록에 아직 없음 (업로드 대기 / 토큰 없음)

    var id: String { clientId }

    init(local t: LocalTrack, recording: Bool) {
        clientId = t.clientId; serverId = t.serverId; name = t.name
        startedAt = t.startedAt; endedAt = t.endedAt; distanceM = t.distanceM
        nPoints = t.points.count; nEst = 0; sentDailyAt = nil; mode = t.mode
        self.recording = recording; localOnly = true
    }

    init(server s: ServerTrack, recording: Bool) {
        clientId = s.clientId; serverId = s.id; name = s.name
        startedAt = s.startedAt ?? 0; endedAt = s.endedAt; distanceM = s.distanceM ?? 0
        nPoints = s.nPoints ?? 0; nEst = s.nEst ?? 0; sentDailyAt = s.sentDailyAt
        mode = TravelMode(rawValue: s.mode ?? "car") ?? .car
        self.recording = recording; localOnly = false
    }
}

/// 경로 기록 목록: 이 기기 + 서버. 밀어서 삭제·데일리요섭 보내기, 길게 눌러 이름·이동 수단
struct TrackListView: View {
    @EnvironmentObject var store: TrackStore
    @EnvironmentObject var settings: AppSettings
    @State private var server: [ServerTrack] = []
    @State private var loadError: String?
    @State private var loading = true

    private var items: [TrackItem] {
        let ids = Set(server.map(\.clientId))
        let activeId = store.active?.clientId
        let locals = store.tracks.reversed()
            .filter { !ids.contains($0.clientId) }
            .map { TrackItem(local: $0, recording: $0.clientId == activeId) }
        return locals + server.map { TrackItem(server: $0, recording: $0.clientId == activeId) }
    }

    var body: some View {
        List {
            if items.isEmpty {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    ContentUnavailableView("저장된 경로 기록이 없습니다", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                           description: Text(loadError.map { "서버 목록을 못 불러왔습니다 (\($0))" } ?? "'기록 시작'을 누르거나, 충전하며 차로 이동하면 자동으로 기록됩니다."))
                }
            }
            ForEach(items) { item in
                TrackRow(item: item, reload: reload)
            }
        }
        .navigationTitle("경로 기록 목록")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: settings.token) { _, _ in Task { await reload() } }
    }

    func reload() async {
        await store.sync()
        guard !settings.token.isEmpty else { server = []; loadError = nil; loading = false; return }
        do {
            server = try await API.tracks()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }
}

struct TrackRow: View {
    let item: TrackItem
    let reload: () async -> Void
    @EnvironmentObject var store: TrackStore
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var toaster: Toaster
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    /// 자동 운전 기록 (이름이 '운전 · …' / '차량 이동 · …')
    private var autoKind: String? {
        if item.name.hasPrefix("운전 · ") { return "운전" }
        if item.name.hasPrefix("차량 이동 · ") { return "차량 이동" }
        return nil
    }

    var body: some View {
        NavigationLink {
            RouteDetailView(item: item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: autoKind == "운전" ? "steeringwheel" : item.mode.symbol)
                    .font(.title3)
                    .foregroundStyle(item.recording ? Color.red : Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.body.weight(.semibold)).lineLimit(2)
                    Text(meta).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    HStack(spacing: 6) {
                        if item.recording { badge("기록 중", .red) }
                        if autoKind != nil { badge("자동", .blue) }
                        if item.localOnly && !item.recording {
                            badge(AppSettings.shared.token.isEmpty ? "이 기기" : "업로드 대기", .gray)
                        }
                        if item.sentDailyAt != nil { badge("데일리요섭", .green) }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing) {
            if !item.recording {
                Button(role: .destructive) { confirmDelete = true } label: { Label("삭제", systemImage: "trash") }
            }
        }
        .swipeActions(edge: .leading) {
            if item.serverId != nil && !item.recording {
                Button { Task { await toggleDaily() } } label: {
                    Label(item.sentDailyAt != nil ? "보내기 취소" : "데일리요섭", systemImage: item.sentDailyAt != nil ? "tray.and.arrow.up" : "paperplane")
                }
                .tint(item.sentDailyAt != nil ? .gray : .green)
            }
        }
        .contextMenu {
            Button("이름 바꾸기", systemImage: "pencil") { newName = item.name; renaming = true }
            Menu {
                ForEach(TravelMode.allCases) { m in
                    Button { Task { await setMode(m) } } label: {
                        Label(m.label, systemImage: m == item.mode ? "checkmark" : m.symbol)
                    }
                }
            } label: { Label("이동 수단", systemImage: item.mode.symbol) }
            if item.serverId != nil && !item.recording {
                Button(item.sentDailyAt != nil ? "데일리요섭 보내기 취소" : "데일리요섭 보내기", systemImage: "paperplane") { Task { await toggleDaily() } }
            }
            if !item.recording {
                Button("삭제", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .alert("이름 바꾸기", isPresented: $renaming) {
            TextField("이름", text: $newName)
            Button("저장") { Task { await saveName() } }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("\"\(item.name)\" 기록을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { Task { await delete() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("되돌릴 수 없습니다.")
        }
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.weight(.semibold)).foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.12), in: Capsule())
    }

    private var meta: String {
        let end = item.endedAt ?? (item.recording ? Date().timeIntervalSince1970 * 1000 : nil)
        var parts = [Fmt.dateKo(item.startedAt) + " " + Fmt.hm(item.startedAt) + (end.map { "–" + Fmt.hm($0) } ?? "")]
        if item.distanceM > 0 { parts.append(String(format: "%.1fkm", item.distanceM / 1000)) }
        if let end { parts.append(Fmt.durKo(end - item.startedAt)) }
        if item.nEst > 0 { parts.append("추정 \(item.nEst)점") }
        return parts.joined(separator: " · ")
    }

    private func setMode(_ m: TravelMode) async {
        guard m != item.mode else { return }
        do {
            if let sid = item.serverId, !AppSettings.shared.token.isEmpty {
                _ = try await API.patch(sid, PatchBody(mode: m.rawValue))
            }
            if item.recording { recorder.mode = m } else { store.setMode(m, for: item.clientId) }
            toaster.show("\(m.emoji) \(m.label)(으)로 변경")
            await reload()
        } catch {
            toaster.show("변경 실패: \(error.localizedDescription)")
        }
    }

    private func saveName() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            if let sid = item.serverId, !AppSettings.shared.token.isEmpty {
                _ = try await API.patch(sid, PatchBody(name: name))
            }
            if store.track(item.clientId) != nil { store.rename(item.clientId, to: name) }
            toaster.show("이름을 바꿨습니다")
            await reload()
        } catch {
            toaster.show("이름 변경 실패: \(error.localizedDescription)")
        }
    }

    private func toggleDaily() async {
        guard let sid = item.serverId else { return }
        do {
            if item.sentDailyAt != nil {
                _ = try await API.sendDaily(sid, false)
                toaster.show("데일리요섭에서 뺐습니다")
            } else {
                _ = try await API.sendDaily(sid, true)
                toaster.show("데일리요섭으로 보냈습니다. 그날 지도에 실제 경로로 나옵니다")
            }
            await reload()
        } catch {
            toaster.show("실패: \(error.localizedDescription)")
        }
    }

    private func delete() async {
        do {
            if let sid = item.serverId, !AppSettings.shared.token.isEmpty { try await API.delete(sid) }
            store.removeLocal(item.clientId)
            toaster.show("삭제했습니다")
            await reload()
        } catch {
            toaster.show("삭제 실패: \(error.localizedDescription)")
        }
    }
}
