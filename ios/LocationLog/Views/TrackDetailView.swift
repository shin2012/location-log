import SwiftUI
import MapKit

struct TrackDetailView: View {
    @State var track: ServerTrack
    var onUpdate: (ServerTrack) -> Void = { _ in }

    @State private var points: [TrackPoint] = []
    @State private var camera: MapCameraPosition = .automatic
    @State private var error: String?
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                Map(position: $camera) {
                    ForEach(Array(TrackGeometry.segments(points).enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg)
                            .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                    if let f = points.first {
                        Marker("출발", coordinate: f.coordinate).tint(.green)
                    }
                    if let l = points.last, points.count > 1 {
                        Marker("도착", coordinate: l.coordinate).tint(.red)
                    }
                }
                .frame(height: 320)
                .listRowInsets(EdgeInsets())
            }

            Section("정보") {
                LabeledContent("시작", value: Fmt.date(track.startedAt))
                LabeledContent("끝", value: Fmt.date(track.endedAt))
                if let s = track.startedAt, let e = track.endedAt {
                    LabeledContent("걸린 시간", value: Fmt.duration((e - s) / 1000))
                }
                LabeledContent("거리", value: Fmt.distance(track.distanceM ?? 0))
                LabeledContent("점", value: "\(track.nPoints ?? points.count)개")
                if let n = track.nEst, n > 0 {
                    LabeledContent("추정 점", value: "\(n)개")
                }
            }

            Section("이동 수단") {
                Picker("이동 수단", selection: modeBinding) {
                    ForEach(TravelMode.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("데일리요섭에 보내기", isOn: dailyBinding)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }
        .navigationTitle(track.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("이름 변경") {
                newName = track.name
                renaming = true
            }
        }
        .alert("이름 변경", isPresented: $renaming) {
            TextField("이름", text: $newName)
            Button("저장") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                Task { await apply { try await API.patch(track.id, PatchBody(name: n)) } }
            }
            Button("취소", role: .cancel) {}
        }
        .task { await load() }
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { track.mode ?? "car" },
            set: { m in Task { await apply { try await API.patch(track.id, PatchBody(mode: m)) } } }
        )
    }

    private var dailyBinding: Binding<Bool> {
        Binding(
            get: { track.sentDailyAt != nil },
            set: { on in Task { await apply { try await API.sendDaily(track.id, on) } } }
        )
    }

    private func apply(_ op: () async throws -> ServerTrack) async {
        do {
            track = try await op()
            onUpdate(track)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        do {
            let d = try await API.track(track.id)
            points = d.points
            track = d.track
            fit()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fit() {
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
