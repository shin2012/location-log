import SwiftUI
import MapKit

/// 이 기기에 저장된 기록 (토큰 없이 쓸 때, 또는 아직 서버에 다 못 올린 기록)
struct LocalTrackDetailView: View {
    let clientId: String
    @EnvironmentObject var store: TrackStore
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .automatic
    @State private var confirmDelete = false

    private var track: LocalTrack? { store.tracks.first { $0.clientId == clientId } }

    var body: some View {
        if let t = track {
            List {
                Section {
                    Map(position: $camera) {
                        ForEach(Array(TrackGeometry.segments(t.points).enumerated()), id: \.offset) { _, seg in
                            MapPolyline(coordinates: seg)
                                .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        }
                        if let f = t.points.first {
                            Marker("출발", coordinate: f.coordinate).tint(.green)
                        }
                        if let l = t.points.last, t.points.count > 1 {
                            Marker("도착", coordinate: l.coordinate).tint(.red)
                        }
                    }
                    .frame(height: 320)
                    .listRowInsets(EdgeInsets())
                }

                Section("정보") {
                    LabeledContent("시작", value: Fmt.date(t.startedAt))
                    LabeledContent("끝", value: t.endedAt == nil ? "기록 중" : Fmt.date(t.endedAt))
                    if let e = t.endedAt {
                        LabeledContent("걸린 시간", value: Fmt.duration((e - t.startedAt) / 1000))
                    }
                    LabeledContent("거리", value: Fmt.distance(t.distanceM))
                    LabeledContent("점", value: "\(t.points.count)개")
                }

                Section("이동 수단") {
                    Picker("이동 수단", selection: Binding(get: { t.mode }, set: { store.setMode($0, for: clientId) })) {
                        ForEach(TravelMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if t.endedAt != nil {
                    Section {
                        Button("기록 삭제", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(t.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { fit(t.points) }
            .confirmationDialog("이 기록을 지울까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    store.delete(clientId)
                    dismiss()
                }
                Button("취소", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("기록 없음", systemImage: "map",
                                   description: Text("서버로 올라갔거나 지워졌습니다"))
        }
    }

    private func fit(_ points: [TrackPoint]) {
        guard !points.isEmpty else { return }
        var rect = MKMapRect.null
        for p in points {
            let mp = MKMapPoint(p.coordinate)
            rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 0, height: 0))
        }
        let pad = max(rect.width, rect.height) * 0.15 + 500
        camera = .rect(rect.insetBy(dx: -pad, dy: -pad))
    }
}
