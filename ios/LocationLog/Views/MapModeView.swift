import SwiftUI
import MapKit

/// 지도 모드: 전체 화면 지도 + 위쪽 오버레이(속도·방향·기록 시간, GPS 상태) + 내 위치 따라가기
struct MapModeView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: TrackStore
    @State private var follow = true

    var body: some View {
        AppMap(lines: (store.active.map { TrackGeometry.runs($0.points) } ?? []).map {
                   // GPS 끊김 구간 추정은 주황 점선
                   MapLine(coords: $0.coords, color: $0.est ? Palette.warn : Palette.route, width: 5, dashed: $0.est)
               },
               showsUser: true, follow: $follow, user: recorder.lastLocation?.coordinate)
        .ignoresSafeArea(edges: .horizontal)
        .overlay(alignment: .top) {
            VStack(alignment: .trailing, spacing: 10) {
                overlayCard
                Button {
                    follow = true
                } label: {
                    Image(systemName: follow ? "location.fill" : "location")
                        .font(.system(size: 18))
                        .foregroundStyle(follow ? Color.blue : Color.primary)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Palette.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("내 위치 따라가기")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
        }
    }

    private var overlayCard: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(spacing: 5) {
                HStack(spacing: 0) {
                    cell("속도") {
                        valueText(recorder.speed.map { "\(Int(($0 * 3.6).rounded()))" } ?? "–", unit: "km/h")
                    }
                    Divider().background(Palette.line).frame(height: 44)
                    cell("방향") {
                        HStack(spacing: 6) {
                            CompassGauge(heading: recorder.heading)
                            Text(Fmt.dirName(recorder.heading))
                                .font(.system(size: 16, weight: .bold))
                                .lineLimit(1)
                        }
                        .frame(height: 30)
                    }
                    Divider().background(Palette.line).frame(height: 44)
                    cell("기록 시간") {
                        valueText(recorder.isRecording ? Fmt.clock(recorder.elapsed) : "대기", unit: nil)
                    }
                }
                StatusLine()
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(.top, 8)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func cell<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.dim)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private func valueText(_ v: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(v).font(.system(size: 21, weight: .bold)).monospacedDigit()
            if let unit {
                Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.dim)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(height: 30)
    }
}
