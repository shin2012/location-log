import SwiftUI
import MapKit
import CoreLocation

/// 자동 체크인: 켜기 · 최근 들어옴/나감 결과(서버 판정) · 장소 목록과 반경
struct AutoCheckinScreen: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toaster: Toaster
    @ObservedObject private var auto = AutoCheckin.shared
    @State private var events: ACEvents?
    @State private var places: [ACPlace] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("자동 체크인", isOn: $auto.enabled)
                    LabeledContent("저장 방식", value: events.map { $0.write ? "체크인 저장" : "기록만 (확인 기간)" } ?? "—")
                    LabeledContent("장소 감시", value: "\(auto.enabled ? auto.places.count : 0) / 19곳")
                    if !auto.pending.isEmpty {
                        LabeledContent("보낼 기록", value: "\(auto.pending.count)건")
                        Button("지금 보내기") { Task { await auto.flush(); await load() } }
                    }
                    if let e = auto.lastError { Text(e).font(.footnote).foregroundStyle(.orange) }
                } footer: {
                    Text("등록한 장소 반경에 들어가면 체크인, 나가면 '나감'으로 기록합니다. 3분 넘게 머물러야 체크인이 되고, 나갔다가 15분 안에 다시 들어오면 나간 것으로 치지 않습니다. 시각은 들어간·나간 순간입니다. '기록만'이면 서버에 남기기만 하고 체크인은 만들지 않습니다(서버 설정). 위치 권한 '항상 허용'이 필요합니다.")
                }

                Section("최근 7일") {
                    if let evs = events?.events, !evs.isEmpty {
                        ForEach(evs) { EventRow(ev: $0) }
                    } else if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Text(settings.token.isEmpty ? "서버에 연결되어 있지 않습니다" : (error ?? "아직 기록이 없습니다"))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach($places) { $pl in
                        NavigationLink {
                            PlaceDetailView(place: $pl)
                        } label: {
                            LabeledContent {
                                Text("반경 \(pl.radius)m")
                            } label: {
                                Label(pl.name, systemImage: pl.enabled == false ? "mappin.slash" : "mappin")
                                    .foregroundStyle(pl.enabled == false ? .secondary : .primary)
                            }
                        }
                        .swipeActions {
                            Button(pl.enabled == false ? "켜기" : "끄기") { Task { await toggle($pl) } }
                                .tint(pl.enabled == false ? .green : .gray)
                        }
                    }
                } header: {
                    Text("장소")
                } footer: {
                    Text("밀어서 켜고 끌 수 있습니다. 장소 추가는 아직 서버에서 합니다.")
                }
            }
            .navigationTitle("자동 체크인")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard !settings.token.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            async let e = API.acEvents(days: 7)
            async let p = API.acPlaces()
            events = try await e
            places = try await p
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggle(_ pl: Binding<ACPlace>) async {
        do {
            pl.wrappedValue = try await API.acPatch(pl.wrappedValue.venueId, ACPlacePatch(enabled: !(pl.wrappedValue.enabled ?? true)))
            await auto.refreshPlaces(force: true)
            toaster.show(pl.wrappedValue.enabled == false ? "\(pl.wrappedValue.name) 감시를 껐습니다" : "\(pl.wrappedValue.name) 감시를 켰습니다")
        } catch {
            toaster.show("바꾸지 못했습니다: \(error.localizedDescription)")
        }
    }
}

private struct EventRow: View {
    let ev: ACEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ev.kind == "enter" ? "arrow.down.right.circle.fill" : "arrow.up.left.circle.fill")
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(ev.name ?? ev.venueId) \(ev.kind == "enter" ? "들어옴" : "나감")").font(.body.weight(.semibold))
                Text("\(Fmt.dateKo(ev.at)) \(Fmt.hm(ev.at)) · \(ev.statusText)")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                if let n = ev.note, !n.isEmpty {
                    Text(n).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch ev.status {
        case "sent", "confirmed": return .green
        case "ignored": return .gray
        case "failed": return .red
        default: return .orange
        }
    }
}

/// 장소 자세히: 지도에 반경 원, 반경·켜기 바꾸기
struct PlaceDetailView: View {
    @Binding var place: ACPlace
    @EnvironmentObject var toaster: Toaster
    @State private var radius: Double = 100
    @State private var saving = false

    var body: some View {
        List {
            Section {
                Map(initialPosition: .region(MKCoordinateRegion(center: place.coordinate, latitudinalMeters: max(600, radius * 5),
                                                                longitudinalMeters: max(600, radius * 5)))) {
                    MapCircle(center: place.coordinate, radius: radius)
                        .foregroundStyle(.blue.opacity(0.2))
                        .stroke(.blue, lineWidth: 2)
                    Marker(place.name, coordinate: place.coordinate)
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            }
            Section {
                Toggle("감시", isOn: Binding(get: { place.enabled ?? true }, set: { v in Task { await save(ACPlacePatch(enabled: v)) } }))
                VStack(alignment: .leading) {
                    LabeledContent("반경", value: "\(Int(radius))m")
                    Slider(value: $radius, in: 50...500, step: 10) { Text("반경") } onEditingChanged: { editing in
                        if !editing { Task { await save(ACPlacePatch(radius: Int(radius))) } }
                    }
                }
            } footer: {
                Text("반경이 너무 작으면 건물 안 GPS 흔들림으로 들어오고 나가는 기록이 생기고, 너무 크면 근처를 지나가기만 해도 잡힙니다. 보통 100~150m.")
            }
            Section {
                LabeledContent("좌표", value: String(format: "%.5f, %.5f", place.lat, place.lon))
                LabeledContent("포스퀘어 장소", value: place.venueId).font(.footnote)
            }
        }
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { radius = Double(place.radius) }
        .disabled(saving)
    }

    private func save(_ patch: ACPlacePatch) async {
        saving = true
        defer { saving = false }
        do {
            place = try await API.acPatch(place.venueId, patch)
            radius = Double(place.radius)
            await AutoCheckin.shared.refreshPlaces(force: true)
            toaster.show("저장했습니다")
        } catch {
            radius = Double(place.radius)
            toaster.show("저장하지 못했습니다: \(error.localizedDescription)")
        }
    }
}
