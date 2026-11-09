import SwiftUI
import MapKit

/// 경로 보기: 전체 지도 + 아래 정보 줄 (이 기기 기록이면 기기 점, 아니면 서버에서 불러옴)
struct RouteDetailView: View {
    let item: TrackItem
    @EnvironmentObject var store: TrackStore
    @Environment(\.dismiss) private var dismiss
    @State private var points: [TrackPoint] = []
    @State private var info = "불러오는 중…"
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
            Map(position: $camera) {
                ForEach(Array(TrackGeometry.runs(points).enumerated()), id: \.offset) { _, run in
                    // GPS 끊김 구간 추정은 주황 점선 (웹판과 같음)
                    MapPolyline(coordinates: run.coords)
                        .stroke(run.est ? Palette.warn : Palette.route,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: run.est ? [6, 8] : []))
                }
                if let f = points.first {
                    Marker("출발", coordinate: f.coordinate).tint(.green)
                }
                if let l = points.last, points.count > 1 {
                    Marker("도착", coordinate: l.coordinate).tint(.red)
                }
            }
            .mapControls { MapScaleView(); MapCompass() }
            .safeAreaInset(edge: .bottom) {
                Text(info)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.dim)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                    .background(.bar)
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { TrackPointsView(points: points) } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("점 목록")
                }
            }
            .task { await load() }
    }

    private func load() async {
        if let l = store.track(item.clientId) {
            points = l.points
            info = line(start: l.startedAt, end: l.endedAt, dist: l.distanceM, n: l.points.count)
        } else if let sid = item.serverId {
            do {
                let d = try await API.track(sid)
                points = d.points
                info = line(start: d.startedAt ?? 0, end: d.endedAt, dist: d.distanceM ?? 0, n: d.nPoints ?? d.points.count)
            } catch {
                info = "불러오기 실패: \(error.localizedDescription)"
            }
        } else {
            info = "점이 없습니다"
        }
        fit()
    }

    private func line(start: Double, end: Double?, dist: Double, n: Int) -> String {
        let e = end ?? points.last?.ts ?? start
        return "\(Fmt.dateKo(start)) \(Fmt.hm(start))–\(Fmt.hm(e)) · \(String(format: "%.2f", dist / 1000))km · \(Fmt.durKo(e - start)) · \(n.formatted())점"
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


/// 기록의 점 목록 (예전 '기록 모드' 화면을 기록 상세 안으로)
struct TrackPointsView: View {
    let points: [TrackPoint]

    var body: some View {
        List(points.reversed(), id: \.seq) { p in
            HStack {
                Text(Fmt.hms(p.ts)).monospacedDigit()
                Text(String(format: "%.5f, %.5f", p.lat, p.lon)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if p.src == "imu" { Text("추정").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                Text(p.spd.map { "\(Int(($0 * 3.6).rounded()))km/h" } ?? "–").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
        .listStyle(.plain)
        .navigationTitle("점 \(points.count.formatted())개")
        .navigationBarTitleDisplayMode(.inline)
    }
}
