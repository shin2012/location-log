import SwiftUI

struct TrackListView: View {
    @EnvironmentObject var store: TrackStore
    @State private var items: [ServerTrack] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if !store.tracks.isEmpty {
                    Section("이 기기 (올리는 중)") {
                        ForEach(store.tracks) { t in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t.name).font(.headline)
                                Text("\(t.endedAt == nil ? "기록 중" : "끝남") · \(Fmt.distance(t.distanceM)) · 안 올린 점 \(t.pendingCount)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("서버") {
                    ForEach(items) { t in
                        NavigationLink(value: t) { row(t) }
                    }
                    .onDelete(perform: delete)
                }
            }
            .navigationTitle("기록 목록")
            .navigationDestination(for: ServerTrack.self) { t in
                TrackDetailView(track: t) { updated in
                    if let i = items.firstIndex(where: { $0.id == updated.id }) { items[i] = updated }
                }
            }
            .refreshable { await load() }
            .task { if !loaded { await load() } }
            .overlay {
                if let error, items.isEmpty {
                    ContentUnavailableView("불러오지 못함", systemImage: "wifi.exclamationmark", description: Text(error))
                }
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
