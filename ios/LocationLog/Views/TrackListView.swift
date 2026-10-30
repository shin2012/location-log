import SwiftUI

struct TrackListView: View {
    @EnvironmentObject var store: TrackStore
    @EnvironmentObject var settings: AppSettings
    @State private var items: [ServerTrack] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if !store.tracks.isEmpty {
                    Section(serverMode ? "이 기기 (올리는 중)" : "이 기기") {
                        ForEach(store.tracks.reversed()) { t in
                            NavigationLink(value: t.clientId) { localRow(t) }
                        }
                        .onDelete { offsets in
                            let list = Array(store.tracks.reversed())
                            for i in offsets where list[i].endedAt != nil { store.delete(list[i].clientId) }
                        }
                    }
                }
                if serverMode {
                    Section("서버") {
                        ForEach(items) { t in
                            NavigationLink(value: t) { row(t) }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationDestination(for: String.self) { cid in
                LocalTrackDetailView(clientId: cid)
            }
            .navigationTitle("기록 목록")
            .navigationDestination(for: ServerTrack.self) { t in
                TrackDetailView(track: t) { updated in
                    if let i = items.firstIndex(where: { $0.id == updated.id }) { items[i] = updated }
                }
            }
            .refreshable { if serverMode { await load() } }
            .task { if serverMode && !loaded { await load() } }
            .overlay {
                if !serverMode && store.tracks.isEmpty {
                    ContentUnavailableView("기록 없음", systemImage: "map",
                                           description: Text("기록 탭에서 시작하면 이 기기에 저장됩니다"))
                } else if serverMode, let error, items.isEmpty {
                    ContentUnavailableView("불러오지 못함", systemImage: "wifi.exclamationmark", description: Text(error))
                }
            }
        }
    }

    /// 토큰이 있으면 서버와 동기화, 없으면 이 기기에만 저장
    private var serverMode: Bool { !settings.token.isEmpty }

    private func localRow(_ t: LocalTrack) -> some View {
        HStack {
            Image(systemName: t.mode.symbol)
                .frame(width: 28)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.name).font(.headline)
                Text("\(t.endedAt == nil ? "기록 중" : Fmt.date(t.startedAt)) · \(Fmt.distance(t.distanceM))"
                     + (serverMode ? " · 안 올린 점 \(t.pendingCount)" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ t: ServerTrack) -> some View {
        HStack {
            Image(systemName: (TravelMode(rawValue: t.mode ?? "car") ?? .car).symbol)
                .frame(width: 28)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.name).font(.headline)
                Text("\(Fmt.date(t.startedAt)) · \(Fmt.distance(t.distanceM ?? 0))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if t.sentDailyAt != nil {
                Image(systemName: "paperplane.fill").foregroundStyle(.green).font(.caption)
            }
        }
    }

    private func load() async {
        do {
            items = try await API.tracks()
            error = nil
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ offsets: IndexSet) {
        let targets = offsets.map { items[$0] }
        items.remove(atOffsets: offsets)
        Task {
            for t in targets {
                do { try await API.delete(t.id) } catch { self.error = error.localizedDescription }
            }
        }
    }
}
