import SwiftUI

/// 경로 기록 (수동): 지도 또는 실시간 점 목록 + 시작/종료. 이동 수단은 끝날 때 자동 인식(목록에서 변경). 지난 기록은 툴바 '목록'.
/// 자동 운전 1초 기록과는 상관없음 (그건 하루 기록에만 저장).
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
            if !recorder.isRecording {
                Text("이동 수단은 기록이 끝나면 자동으로 정해집니다. 목록에서 바꿀 수 있습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
