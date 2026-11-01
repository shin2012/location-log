import SwiftUI

/// 기록 모드: 기록 중이면 위쪽 요약 + `시각  위도, 경도  속도` 줄이 계속 아래로 붙음
struct LogModeView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: TrackStore
    @State private var stick = true
    @State private var blink = false

    var body: some View {
        VStack(spacing: 0) {
            if recorder.isRecording, let t = store.active {
                header(t)
                columns
                list(t.points)
            } else {
                idle
            }
        }
        .background(Palette.bg)
    }

    private func header(_ t: LocalTrack) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(Palette.rec).frame(width: 10, height: 10)
                        .opacity(blink ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: blink)
                        .onAppear { blink = true }
                    Text("기록 중").font(.system(size: 15, weight: .bold))
                    Spacer()
                    Text(Fmt.clock(recorder.elapsed)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                }
                HStack(spacing: 8) {
                    stat(String(format: t.distanceM < 10000 ? "%.2f" : "%.1f", t.distanceM / 1000), "km", "거리")
                    stat(recorder.speed.map { "\(Int(($0 * 3.6).rounded()))" } ?? "–", "km/h", "속도")
                    stat(t.points.count.formatted(), "개", "기록한 위치")
                }
                StatusLine(showCount: false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(Color(red: 0.059, green: 0.075, blue: 0.102))
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
    }

    private func stat(_ v: String, _ unit: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(v).font(.system(size: 19, weight: .bold)).monospacedDigit()
                Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.dim)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.dim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
    }

    private var columns: some View {
        HStack(spacing: 8) {
            Text("시각").frame(width: 70, alignment: .leading)
            Text("위도, 경도").frame(maxWidth: .infinity, alignment: .leading)
            Text("속도").frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.dim)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private enum Row: Identifiable {
        case gap(id: Int, text: String)
        case point(TrackPoint, last: Bool)
        var id: Int {
            switch self {
            case .gap(let id, _): return -id - 1
            case .point(let p, _): return p.seq
            }
        }
    }

    /// 마지막 500점 (20초 넘게 비면 "N분 동안 기록 없음" 줄)
    private func rows(_ pts: [TrackPoint]) -> [Row] {
        let tail = pts.suffix(500)
        var out: [Row] = []
        var prev: TrackPoint?
        for p in tail {
            if let q = prev, p.ts - q.ts > 20000 {
                out.append(.gap(id: p.seq, text: "\(Fmt.durKo(p.ts - q.ts)) 동안 기록 없음"))
            }
            out.append(.point(p, last: p.seq == tail.last?.seq))
            prev = p
        }
        return out
    }

    private func list(_ pts: [TrackPoint]) -> some View {
        let rs = rows(pts)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rs) { r in
                        switch r {
                        case .gap(_, let text):
                            Text(text)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 0.392, green: 0.455, blue: 0.545))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
                        case .point(let p, let last):
                            pointRow(p, last: last).id(r.id)
                        }
                    }
                }
                .padding(.bottom, 110)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(StickToBottom(stick: $stick))
            .onChange(of: pts.count) { _, _ in
                if stick, let last = pts.last { proxy.scrollTo(last.seq, anchor: .bottom) }
            }
            .onAppear {
                if let last = pts.last { proxy.scrollTo(last.seq, anchor: .bottom) }
            }
        }
    }

    private func pointRow(_ p: TrackPoint, last: Bool) -> some View {
        HStack(spacing: 8) {
            Text(Fmt.hms(p.ts)).foregroundStyle(Palette.dim).frame(width: 70, alignment: .leading)
            (Text(String(format: "%.5f, %.5f", p.lat, p.lon))
             + (p.src == "imu" ? Text(" 추정").font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.warn) : Text("")))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(p.spd.map { "\(Int(($0 * 3.6).rounded()))" } ?? "–")
                Text("km/h").font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
            .foregroundStyle(Color(red: 0.796, green: 0.835, blue: 0.882))
            .frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 14))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(last ? Color(red: 0.231, green: 0.510, blue: 0.965).opacity(0.1) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
        .textSelection(.enabled)
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("📍")
                .font(.system(size: 26))
                .frame(width: 64, height: 64)
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 2))
            Text("기록 중이 아닙니다").font(.system(size: 18, weight: .bold))
            (Text("아래 ") + Text("● 기록 시작").bold() + Text("을 누르면\n위치가 여기에 시간순으로 쌓입니다"))
                .font(.system(size: 14))
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Spacer()
            Spacer().frame(height: 120)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 사용자가 위로 올려 보고 있으면 새 줄이 와도 자동으로 내리지 않음 (iOS 18+)
struct StickToBottom: ViewModifier {
    @Binding var stick: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { g in
                g.contentSize.height - g.contentOffset.y - g.containerSize.height < 60
            } action: { _, near in
                stick = near
            }
        } else {
            content
        }
    }
}
