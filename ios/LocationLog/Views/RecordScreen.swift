import SwiftUI

/// 경로 기록 (수동): 지도 또는 실시간 점 목록 + 이동 수단 + 시작/종료. 지난 기록은 툴바 '목록'.
struct RecordScreen: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var toaster: Toaster
    @AppStorage("recordView") private var view = "map"
    @State private var confirmStop = false
    @State private var haptic = false

    var body: some View {
        NavigationStack {
            Group {
                if view == "log" { LogModeView() } else { MapModeView() }
            }
            .navigationTitle("경로 기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("보기", selection: $view) {
                        Label("지도", systemImage: "map").tag("map")
                        Label("점 목록", systemImage: "list.bullet").tag("log")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { TrackListView() } label: { Image(systemName: "list.bullet.rectangle") }
                        .accessibilityLabel("경로 기록 목록")
                }
            }
            .safeAreaInset(edge: .bottom) { controls }
            .confirmationDialog("경로 기록을 끝낼까요?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("기록 종료", role: .destructive) {
                    haptic.toggle()
                    if let name = recorder.stop() { toaster.show("\"\(name)\" 저장했습니다") }
                }
                Button("계속 기록", role: .cancel) {}
            }
            .sensoryFeedback(.impact, trigger: haptic)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("이동 수단", selection: $recorder.mode) {
                ForEach(TravelMode.allCases) { m in Label(m.label, systemImage: m.symbol).tag(m) }
            }
            .pickerStyle(.segmented)
            Button {
                if recorder.isRecording { confirmStop = true } else { haptic.toggle(); recorder.start() }
            } label: {
                Label(recorder.isRecording ? "기록 종료" : "기록 시작",
                      systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(recorder.isRecording ? .red : .accentColor)
            if recorder.isRecording && recorder.isAuto {
                Text("충전 중 차로 이동해 자동으로 켠 기록입니다. 내리면 자동으로 끝납니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
