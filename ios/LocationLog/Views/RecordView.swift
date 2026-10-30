import SwiftUI
import MapKit

struct RecordView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: TrackStore
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var confirmStop = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                UserAnnotation()
                if let t = store.active {
                    ForEach(Array(TrackGeometry.segments(t.points).enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg)
                            .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }

            VStack(spacing: 12) {
                statsCard
                controls
            }
            .padding()
        }
        .onAppear { recorder.requestPermission() }
        .confirmationDialog("기록을 끝낼까요?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("끝내기", role: .destructive) { recorder.stop() }
            Button("계속 기록", role: .cancel) {}
        }
    }

    private var statsCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    stat("시간", recorder.isRecording ? Fmt.duration(recorder.elapsed) : "-")
                    stat("거리", Fmt.distance(store.active?.distanceM ?? 0))
                    stat("속도", Fmt.speed(recorder.lastLocation?.speed))
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(recorder.status)
                    Spacer()
                    if store.pendingPoints > 0 {
                        Text("안 올린 점 \(store.pendingPoints)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let e = store.lastSyncError {
                    Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
                if recorder.authorization == .denied || recorder.authorization == .restricted {
                    Text("위치 권한이 꺼져 있음 — 설정 앱에서 '항상'으로 켜 주세요")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit()).bold()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("이동 수단", selection: $recorder.mode) {
                ForEach(TravelMode.allCases) { m in
                    Label(m.label, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Button {
                if recorder.isRecording { confirmStop = true } else { recorder.start() }
            } label: {
                Text(recorder.isRecording ? "기록 끝내기" : "기록 시작")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .blue)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
