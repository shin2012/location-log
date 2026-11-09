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
    @State private var adding = false
    @State private var deleting: ACPlace?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("자동 체크인", isOn: $auto.enabled)
                    LabeledContent("저장 방식", value: events.map { $0.write ? "체크인 저장" : "기록만 (확인 기간)" } ?? "—")
                    LabeledContent("장소 감시", value: "\(auto.enabled ? auto.places.count : 0)곳")
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
                            PlaceDetailView(place: $pl) { places.removeAll { $0.id == pl.id } }
                        } label: {
                            LabeledContent {
                                Text("반경 \(pl.radius)m")
                            } label: {
                                Label(pl.name, systemImage: pl.enabled == false ? "mappin.slash" : "mappin")
                                    .foregroundStyle(pl.enabled == false ? .secondary : .primary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = pl } label: { Label("삭제", systemImage: "trash") }
                            Button(pl.enabled == false ? "켜기" : "끄기") { Task { await toggle($pl) } }
                                .tint(pl.enabled == false ? .green : .gray)
                        }
                    }
                    Button { startAdd() } label: { Label("장소 추가", systemImage: "plus") }
                        .disabled(settings.token.isEmpty)
                } header: {
                    Text("장소 \(places.count)곳")
                } footer: {
                    Text("밀어서 끄거나 지울 수 있습니다.")
                }
            }
            .navigationTitle("자동 체크인")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startAdd() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("장소 추가")
                        .disabled(settings.token.isEmpty)
                }
            }
            .sheet(isPresented: $adding) {
                AddPlaceSheet { pl in places.append(pl); places.sort { $0.name < $1.name } }
            }
            .confirmationDialog("\"\(deleting?.name ?? "")\" 장소를 지울까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("삭제", role: .destructive) { if let d = deleting { Task { await delete(d) } } }
                Button("취소", role: .cancel) {}
            } message: { Text("지난 들어옴·나감 기록은 남습니다.") }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var enabledCount: Int { places.filter { $0.enabled != false }.count }

    /// 켜진 장소가 이미 최대면 추가 화면 대신 안내
    private func startAdd() {
        if enabledCount >= AutoCheckin.maxPlaces { toaster.show(AutoCheckin.maxMessage) } else { adding = true }
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

    private func delete(_ pl: ACPlace) async {
        do {
            try await API.acDelete(pl.venueId)
            places.removeAll { $0.id == pl.id }
            await auto.refreshPlaces(force: true)
            toaster.show("\(pl.name) 삭제했습니다")
        } catch {
            toaster.show("지우지 못했습니다: \(error.localizedDescription)")
        }
        deleting = nil
    }

    private func toggle(_ pl: Binding<ACPlace>) async {
        if pl.wrappedValue.enabled == false && enabledCount >= AutoCheckin.maxPlaces {
            toaster.show(AutoCheckin.maxMessage)
            return
        }
        do {
            pl.wrappedValue = try await API.acPatch(pl.wrappedValue.venueId, ACPlacePatch(enabled: !(pl.wrappedValue.enabled ?? true)))
            await auto.refreshPlaces(force: true)
            toaster.show(pl.wrappedValue.enabled == false ? "\(pl.wrappedValue.name) 감시를 껐습니다" : "\(pl.wrappedValue.name) 감시를 켰습니다")
        } catch {
            toaster.show("바꾸지 못했습니다: \(PlaceDetailView.friendly(error))")
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

/// 장소 자세히: 지도에 반경 원, 이름·반경·중심·켜기 바꾸기, 삭제
struct PlaceDetailView: View {
    @Binding var place: ACPlace
    var onDelete: () -> Void = {}
    @EnvironmentObject var toaster: Toaster
    @Environment(\.dismiss) private var dismiss
    @State private var radius: Double = 100
    @State private var name = ""
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var confirmMove = false

    var body: some View {
        List {
            Section {
                AppMap(circles: [MapCircleArea(center: place.coordinate, radius: radius)],
                       fit: MapFit(key: "\(place.lat),\(place.lon),\(Int(radius / 50))",
                                   coords: ring(place.coordinate, radius * 1.6)),
                       showsUser: true)
                    .frame(height: 280)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                TextField("이름", text: $name)
                    .submitLabel(.done)
                    .onSubmit {
                        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !n.isEmpty && n != place.name { Task { await save(ACPlacePatch(name: n)) } }
                    }
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
                Button("중심을 지금 위치로 옮기기", systemImage: "location") { confirmMove = true }
                LabeledContent("좌표", value: String(format: "%.5f, %.5f", place.lat, place.lon))
                LabeledContent("포스퀘어 장소", value: place.venueId).font(.footnote)
            } footer: {
                Text("감시 중심은 이 장소에서 실제로 머무는 자리입니다. 그 장소 안에 있을 때 누르세요.")
            }
            Section {
                Button("장소 삭제", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { radius = Double(place.radius); name = place.name }
        .disabled(saving)
        .confirmationDialog("중심을 지금 위치로 옮길까요?", isPresented: $confirmMove, titleVisibility: .visible) {
            Button("옮기기") { Task { await moveHere() } }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("\"\(place.name)\" 장소를 지울까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { Task { await delete() } }
            Button("취소", role: .cancel) {}
        } message: { Text("지난 들어옴·나감 기록은 남습니다.") }
    }

    /// 서버의 최대 개수 거절은 '서버 오류 409:' 없이 안내 문구만
    static func friendly(_ e: Error) -> String {
        let m = e.localizedDescription
        return m.contains(AutoCheckin.maxMessage) ? AutoCheckin.maxMessage : m
    }

    /// 원이 화면에 다 들어오게 맞출 네 점
    private func ring(_ c: CLLocationCoordinate2D, _ r: Double) -> [CLLocationCoordinate2D] {
        let dLat = r / 111_000, dLon = r / (111_000 * cos(c.latitude * .pi / 180))
        return [.init(latitude: c.latitude - dLat, longitude: c.longitude - dLon), .init(latitude: c.latitude + dLat, longitude: c.longitude + dLon)]
    }

    private func moveHere() async {
        guard let l = DayLogger.shared.currentLocation(), l.horizontalAccuracy >= 0, l.horizontalAccuracy < 100 else {
            toaster.show("지금 위치가 정확하지 않습니다 (100m 안으로 잡힐 때 다시)")
            return
        }
        await save(ACPlacePatch(lat: l.coordinate.latitude, lon: l.coordinate.longitude))
    }

    private func delete() async {
        do {
            try await API.acDelete(place.venueId)
            await AutoCheckin.shared.refreshPlaces(force: true)
            toaster.show("\(place.name) 삭제했습니다")
            onDelete()
            dismiss()
        } catch {
            toaster.show("지우지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func save(_ patch: ACPlacePatch) async {
        saving = true
        defer { saving = false }
        do {
            place = try await API.acPatch(place.venueId, patch)
            radius = Double(place.radius)
            name = place.name
            await AutoCheckin.shared.refreshPlaces(force: true)
            toaster.show("저장했습니다")
        } catch {
            radius = Double(place.radius)
            name = place.name
            toaster.show("저장하지 못했습니다: \(Self.friendly(error))")
        }
    }
}

/// 장소 추가: 내가 체크인했던 곳 중 고르기 (가까운 순 / 이름 검색)
struct AddPlaceSheet: View {
    let onAdded: (ACPlace) -> Void
    @EnvironmentObject var toaster: Toaster
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var venues: [ACVenue] = []
    @State private var loading = false
    @State private var error: String?
    @State private var busy: String?

    private var here: CLLocationCoordinate2D? { DayLogger.shared.currentLocation()?.coordinate }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(venues) { v in
                        Button { Task { await add(v) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(v.name).foregroundStyle(v.added ? .secondary : .primary)
                                    Text(sub(v)).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if busy == v.id { ProgressView() }
                                else if v.added { Text("등록됨").font(.footnote).foregroundStyle(.secondary) }
                                else { Image(systemName: "plus.circle").foregroundStyle(Color.accentColor) }
                            }
                        }
                        .disabled(v.added || busy != nil)
                    }
                    if venues.isEmpty && !loading {
                        Text(error ?? (q.isEmpty ? "근처에 체크인했던 곳이 없습니다. 이름으로 찾아 보세요." : "찾는 장소가 없습니다"))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(q.isEmpty ? "근처에서 체크인했던 곳" : "검색 결과")
                } footer: {
                    Text("스웜에 체크인했던 장소만 고를 수 있습니다(자동 체크인이 그 장소로 체크인을 만듦). 감시 중심은 그 장소에서 실제로 머물렀던 자리로 맞춥니다.")
                }
            }
            .overlay { if loading && venues.isEmpty { ProgressView() } }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "장소 이름")
            .task(id: q) {
                try? await Task.sleep(for: .milliseconds(q.isEmpty ? 0 : 350))
                if !Task.isCancelled { await search() }
            }
            .navigationTitle("장소 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func sub(_ v: ACVenue) -> String {
        var parts: [String] = []
        if let c = v.category, !c.isEmpty { parts.append(c) }
        if let d = v.distM { parts.append(d < 1000 ? "\(d)m" : String(format: "%.1fkm", Double(d) / 1000)) }
        parts.append("체크인 \(v.n)번")
        return parts.joined(separator: " · ")
    }

    private func search() async {
        loading = true
        defer { loading = false }
        do {
            venues = try await API.acVenues(q: q.trimmingCharacters(in: .whitespaces), near: here)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(_ v: ACVenue) async {
        busy = v.id
        defer { busy = nil }
        do {
            let p = try await API.acAdd(ACPlaceNew(venueId: v.venueId, name: v.name, lat: v.lat, lon: v.lon))
            await AutoCheckin.shared.refreshPlaces(force: true)
            onAdded(p)
            toaster.show("\(v.name) 추가했습니다")
            dismiss()
        } catch {
            toaster.show("추가하지 못했습니다: \(PlaceDetailView.friendly(error))")
        }
    }
}
