import SwiftUI

@main
struct LocationLogApp: App {
    @StateObject private var store: TrackStore
    @StateObject private var recorder: Recorder
    @StateObject private var toaster = Toaster()
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
                .environmentObject(toaster)
                .environmentObject(AppSettings.shared)
                .preferredColorScheme(.dark)
                // 앱이 앞에 있는 동안 5초마다 서버로 올림 (백그라운드에서는 Recorder가 위치 받을 때 올림)
                .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                    Task { await store.sync() }
                }
                .onChange(of: phase) { _, p in
                    recorder.setForeground(p == .active)
                    if p == .active { Task { await store.sync() } } else { store.save(force: true) }
                }
        }
    }
}

/// 웹판과 같은 한 화면: 지도 모드 / 기록 모드 + 아래 버튼 3개(화면 전환 · 기록 시작/종료 · 설정)
struct RootView: View {
    @EnvironmentObject var store: TrackStore
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var toaster: Toaster
    @EnvironmentObject var settings: AppSettings
    @AppStorage("viewMode") private var viewMode = "map"
    @State private var showSettings = false
    @State private var confirmStop = false

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            if viewMode == "log" { LogModeView() } else { MapModeView() }
            BottomBar(viewMode: $viewMode, showSettings: $showSettings, confirmStop: $confirmStop)
            ToastView()
        }
        .onAppear { recorder.requestPermission() }
        .confirmationDialog("기록을 끝낼까요?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("기록 종료", role: .destructive) {
                if let name = recorder.stop() { toaster.show("\"\(name)\" 저장했습니다") }
            }
            Button("계속 기록", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(toaster)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}

struct BottomBar: View {
    @EnvironmentObject var recorder: Recorder
    @Binding var viewMode: String
    @Binding var showSettings: Bool
    @Binding var confirmStop: Bool

    var body: some View {
        VStack {
            Spacer()
            HStack {
                SmallCircleButton(systemImage: viewMode == "map" ? "list.bullet.rectangle" : "map",
                                  label: viewMode == "map" ? "기록 화면으로" : "지도 화면으로") {
                    viewMode = viewMode == "map" ? "log" : "map"
                }
                Spacer()
                Button {
                    if recorder.isRecording { confirmStop = true } else { recorder.start() }
                } label: {
                    Text(recorder.isRecording ? "■ 기록 종료" : "● 기록 시작")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 172, minHeight: 64)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(recorder.isRecording ? Palette.rec : Palette.blue))
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                }
                .buttonStyle(.plain)
                Spacer()
                SmallCircleButton(systemImage: "gearshape", label: "설정") { showSettings = true }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
    }
}

struct SmallCircleButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Palette.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
