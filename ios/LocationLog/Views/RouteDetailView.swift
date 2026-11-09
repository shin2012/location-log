import SwiftUI
import MapKit

/// 경로 보기: 전체 지도 + 아래 정보 줄 (이 기기 기록이면 기기 점, 아니면 서버에서 불러옴)
struct RouteDetailView: View {
    let item: TrackItem
    @EnvironmentObject var store: TrackStore
    @Environment(\.dismiss) private var dismiss
    @State private var points: [TrackPoint] = []
    @State private var info = "불러오는 중…"

    var body: some View {
            AppMap(lines: TrackGeometry.runs(points).map { MapLine(coords: $0.coords, color: $0.est ? Palette.warn : Palette.route, dashed: $0.est) },
                   pins: [points.first.map { MapPin(id: "s", coord: $0.coordinate, title: "출발", color: .green) },
                          points.count > 1 ? points.last.map { MapPin(id: "e", coord: $0.coordinate, title: "도착", color: .red) } : nil].compactMap { $0 },
                   fit: points.isEmpty ? nil : MapFit(key: "\(item.id)-\(points.count)", coords: points.map(\.coordinate)))
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

    private func fit() {}   // AppMap 이 fit 키로 맞춤

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
