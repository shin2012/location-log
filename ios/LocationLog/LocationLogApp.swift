import SwiftUI

@main
struct LocationLogApp: App {
    @StateObject private var store: TrackStore
    @StateObject private var recorder: Recorder
    @Environment(\.scenePhase) private var phase

    init() {
        let s = TrackStore()
        _store = StateObject(wrappedValue: s)
        _recorder = StateObject(wrappedValue: Recorder(store: s))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(AppSettings.shared)
                // 앱이 켜져 있는 동안 5초마다 서버로 올림 (백그라운드에서는 Recorder가 위치 받을 때 올림)
                .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                    Task { await store.sync() }
                }
                .onChange(of: phase) { _, p in
                    if p != .active { store.save(force: true) }
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("기록", systemImage: "record.circle") }
            TrackListView()
                .tabItem { Label("목록", systemImage: "list.bullet") }
            SettingsView()
                .tabItem { Label("설정", systemImage: "gearshape") }
        }
    }
}
