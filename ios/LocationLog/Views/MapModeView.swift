import SwiftUI
import MapKit

/// 지도 모드: 전체 화면 지도 + 위쪽 오버레이(속도·방향·기록 시간, GPS 상태) + 내 위치 따라가기
struct MapModeView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: TrackStore
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            if let t = store.active {
                ForEach(Array(TrackGeometry.runs(t.points).enumerated()), id: \.offset) { _, run in
                    // GPS 끊김 구간 추정은 주황 점선 (웹판과 같음)
                    MapPolyline(coordinates: run.coords)
                        .stroke(run.est ? Palette.warn : Palette.route,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: run.est ? [6, 8] : []))
                }
            }
        }
        .mapControls { MapScaleView() }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            VStack(alignment: .trailing, spacing: 10) {
                overlayCard
                Button {
                    withAnimation { camera = .userLocation(fallback: .automatic) }
                } label: {
                    Image(systemName: camera.followsUserLocation ? "location.fill" : "location")
                        .font(.system(size: 18))
                        .foregroundStyle(camera.followsUserLocation ? Color(red: 0.376, green: 0.647, blue: 0.980) : .white)
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
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
