import SwiftUI
import UserNotifications

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
        // 주차 층 알림 버튼은 앱이 꺼져 있어도 백그라운드로 켜져 여기서 받음 → boot 전에 delegate
        UNUserNotificationCenter.current().delegate = NotifDelegate.shared
        Parking.registerCategory()
        DayLogger.shared.boot(recorder: r)
        MapServices.shared.boot()
        #if DEBUG
        // CI 화면 캡처용: 실행 인자 -shotToken <토큰> (Debug 빌드에서만)
        if let t = UserDefaults.standard.string(forKey: "shotToken"), !t.isEmpty { AppSettings.shared.token = t }
        #endif
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
