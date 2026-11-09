import SwiftUI

/// 앱 구성: 타임라인 · 자동 체크인 · 경로 기록 · 설정
/// iPhone(좁은 화면) = 아래 탭 막대, iPad(넓은 화면) = 왼쪽 사이드바 (NavigationSplitView).
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case timeline, autoCheckin, record, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: return "타임라인"
        case .autoCheckin: return "자동 체크인"
        case .record: return "경로 기록"
        case .settings: return "설정"
        }
    }

    var symbol: String {
        switch self {
        case .timeline: return "calendar.day.timeline.left"
        case .autoCheckin: return "mappin.and.ellipse"
        case .record: return "record.circle"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var toaster: Toaster
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("tab") private var tab: AppTab = .timeline

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(AppTab.allCases, selection: Binding<AppTab?>(get: { tab }, set: { if let t = $0 { tab = t } })) { t in
                        Label(t.title, systemImage: t.symbol).tag(t)
                    }
                    .navigationTitle("시야쥬")
                } detail: {
                    screen(tab)
                }
            } else {
                TabView(selection: $tab) {
                    ForEach(AppTab.allCases) { t in
                        screen(t)
                            .tabItem { Label(t.title, systemImage: t.symbol) }
                            .tag(t)
                    }
                }
            }
        }
        .overlay { ToastView() }
        .onAppear { recorder.requestPermission() }
        .onReceive(recorder.$lastCorrection.compactMap { $0 }) { c in
            toaster.show("GPS 끊김 \(Int(c.gapS.rounded()))초 구간을 다시 잡힌 위치에 맞춰 보정했습니다 (차이 \(Int(c.errM.rounded()))m)", seconds: 4)
        }
    }

    @ViewBuilder private func screen(_ t: AppTab) -> some View {
        Group {
            switch t {
            case .timeline: TimelineScreen()
            case .autoCheckin: AutoCheckinScreen()
            case .record: RecordScreen()
            case .settings: SettingsScreen()
            }
        }
        // 경로 기록 중이면 어느 화면에서든 아래에 상태 줄 (누르면 경로 기록으로)
        .safeAreaInset(edge: .bottom) {
            if recorder.isRecording && t != .record {
                RecordingBanner { tab = .record }
            }
        }
    }
}

/// "● 경로 기록 중 · 12:03 · 8.4km" — 탭 막대 바로 위
struct RecordingBanner: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: TrackStore
    @ObservedObject private var logger = DayLogger.shared
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse)
                    Text(logger.autoDriving ? (CarPlayWatcher.shared.connected ? "운전 기록 중" : "차량 이동 기록 중") : "경로 기록 중")
                        .fontWeight(.semibold)
                    Text(Fmt.clock(recorder.elapsed)).monospacedDigit()
                    if let d = store.active?.distanceM, d > 0 {
                        Text(String(format: "%.1fkm", d / 1000)).monospacedDigit()
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("경로 기록 중, 경로 기록 화면으로 이동")
    }
}
