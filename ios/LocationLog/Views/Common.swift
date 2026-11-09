import SwiftUI

/// 시스템 색 (라이트·다크 자동). 예전 고정 다크 색 대신.
enum Palette {
    static let bg = Color(uiColor: .systemBackground)
    static let card = Color(uiColor: .secondarySystemBackground)
    static let line = Color(uiColor: .separator)
    static let dim = Color.secondary
    static let rec = Color.red
    static let warn = Color.orange
    static let ok = Color.green
    static let blue = Color.blue
    static let route = Color.blue
    static let drive = Color.red          // 운전 (CarPlay)
    static let ride = Color.orange        // 차량 이동 (운전 아님)
    static let walk = Color.green
    static let bike = Color.teal
}

/// 잠깐 떴다 사라지는 안내
@MainActor
final class Toaster: ObservableObject {
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?

    func show(_ m: String, seconds: Double = 3) {
        message = m
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.message = nil }
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var toaster: Toaster

    var body: some View {
        VStack {
            Spacer()
            if let m = toaster.message {
                Text(m)
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toaster.message)
        .allowsHitTesting(false)
    }
}

/// 상태 줄: "GPS ±8m · 1,234점 · 업로드 대기"
struct StatusLine: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: TrackStore
    @EnvironmentObject var settings: AppSettings
    var showCount = true

    var body: some View {
        let st = recorder.status()
        var t: Text
        switch st.kind {
        case .ok:
            t = Text("GPS").bold().foregroundColor(Palette.ok) + Text(st.text.dropFirst(3))
        case .warn:
            t = Text(st.text).bold().foregroundColor(Palette.warn)
        case .plain:
            t = Text(st.text)
        }
        if showCount && recorder.isRecording {
            t = t + Text(" · \((store.active?.points.count ?? 0).formatted())점")
        }
        if !settings.token.isEmpty && store.lastSyncError != nil {
            t = t + Text(" · ") + Text("업로드 대기").bold().foregroundColor(Palette.warn)
        }
        return t
            .font(.system(size: 12))
            .foregroundColor(Palette.dim)
            .monospacedDigit()
    }
}

/// 방향 게이지 (웹 svg와 같은 모양). 359°→0°에서 바늘이 한 바퀴 돌지 않게 누적 각도로 돌림
struct CompassGauge: View {
    let heading: Double?
    @State private var needle: Double = 0

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.05))
            Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1.2)
            ForEach(0..<4) { i in
                Rectangle()
                    .fill(Color.primary.opacity(0.33))
                    .frame(width: 1.2, height: 2.6)
                    .offset(y: -12.5)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            Text("N")
                .font(.system(size: 5.5, weight: .heavy))
                .foregroundStyle(.red)
                .offset(y: -8.5)
            NeedleShape()
                .fill(Color.blue)
                .frame(width: 30, height: 30)
                .rotationEffect(.degrees(needle))
                .opacity(heading == nil ? 0.25 : 1)
                .animation(.easeOut(duration: 0.4), value: needle)
        }
        .frame(width: 30, height: 30)
        .onAppear { if let h = heading { needle = h } }
        .onChange(of: heading) { _, h in
            guard let h else { return }
            let d = ((h - needle).truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
            needle += d
        }
    }
}

/// svg path "M20 8 L25.5 26 L20 22.5 L14.5 26 Z" (40×40 기준)
struct NeedleShape: Shape {
    func path(in r: CGRect) -> Path {
        let s = r.width / 40
        var p = Path()
        p.move(to: CGPoint(x: 20 * s, y: 8 * s))
        p.addLine(to: CGPoint(x: 25.5 * s, y: 26 * s))
        p.addLine(to: CGPoint(x: 20 * s, y: 22.5 * s))
        p.addLine(to: CGPoint(x: 14.5 * s, y: 26 * s))
        p.closeSubpath()
        return p
    }
}
