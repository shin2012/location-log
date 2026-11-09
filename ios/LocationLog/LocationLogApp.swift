import SwiftUI

@main
struct LocationLogApp: App {
    @StateObject private var store: TrackStore
    @StateObject private var recorder: Recorder
    @StateObject private var toaster = Toaster()
    @Environment(\.scenePhase) private var phase

    init() {
        let s = TrackStore()
        let r = Recorder(store: s)
        _store = StateObject(wrappedValue: s)
        _recorder = StateObject(wrappedValue: r)
        // 하루 종일 기록: 위치 알림으로 앱이 백그라운드에서 다시 켜져도 여기서 이어짐
        DayLogger.shared.boot(recorder: r)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(toaster)
                .environmentObject(AppSettings.shared)
                // 앱이 앞에 있는 동안 5초마다 서버로 올림 (백그라운드에서는 Recorder가 위치 받을 때 올림)
                .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                    Task { await store.sync() }
                }
                .onChange(of: phase) { _, p in
                    recorder.setForeground(p == .active)
                    DayLogger.shared.setForeground(p == .active)
                    if p == .active { Task { await store.sync() } } else { store.save(force: true) }
                }
        }
    }
}
