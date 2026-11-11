import SwiftUI
import MapKit

/// 타임라인: 그날 지도 + 머문 곳·이동 목록 (서버 /api/day/{date}/timeline)
struct TimelineScreen: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var logger = DayLogger.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var day: Date = {
        #if DEBUG
        // CI 화면 캡처용: 실행 인자 -shotDay YYYY-MM-DD
        if let d = UserDefaults.standard.string(forKey: "shotDay"), let x = DayLogStore.dayFmt.date(from: d) { return x }
        #endif
        return Calendar.current.startOfDay(for: Date())
    }()
    @State private var data: TimelineDay?
    @State private var error: String?
    @State private var loading = false
    @State private var selected: TimelineItem?
    @State private var detail: TimelineItem?
    @State private var picking = false
    @State private var showPoints = false
    @State private var fitReq: MapFit?

    private var key: String { DayLogStore.dayFmt.string(from: day) }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        NavigationStack {
            Group {
                if sizeClass == .regular {
                    HStack(spacing: 0) {
                        list.frame(minWidth: 340, idealWidth: 400, maxWidth: 440)
                        Divider()
                        map
                    }
                } else {
                    list
                }
            }
            .navigationTitle(title)
            .toolbar { toolbar }
            .sheet(isPresented: $picking) { datePicker }
            .sheet(item: $detail) { TimelineDetailSheet(item: $0) }
            .navigationDestination(isPresented: $showPoints) { DayMapView(day: key) }
            .task(id: key) { await load() }
            .refreshable { await load() }
            // '타임라인' 탭을 다시 누르면(더블탭) 무조건 오늘로 — 이미 오늘이면 새로 불러옴
            .onReceive(NotificationCenter.default.publisher(for: AppTab.reselected)) { n in
                guard n.object as? AppTab == .timeline else { return }
                picking = false; detail = nil; showPoints = false; selected = nil
                let today = Calendar.current.startOfDay(for: Date())
                if isToday { Task { await load() } } else { day = today }
            }
        }
    }

    private var title: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E)"
        return f.string(from: day)
    }

    // MARK: 목록

    private var list: some View {
        List {
            if logger.running && isToday {
                Section {
                    Label(logger.statusText, systemImage: logger.autoDriving ? "steeringwheel" : "location.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if sizeClass != .regular {
                Section {
                    map.frame(height: 260).listRowInsets(EdgeInsets())
                }
            }
            if let s = data?.summary {
                Section {
                    HStack {
                        stat("\(String(format: "%.1f", s.km))km", "이동")
                        Divider()
                        stat(s.steps.formatted(), "걸음")
                        Divider()
                        stat(Fmt.durKo(Double(s.driveMin) * 60_000), "운전")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Section {
                if let items = data?.items, !items.isEmpty {
                    ForEach(items) { it in
                        HStack(spacing: 8) {
                            Button { select(it) } label: { TimelineRow(item: it) }
                                .buttonStyle(.plain)
                            if let pk = it.park {
                                ParkMenu(park: pk) { lv in await setPark(pk, lv) }
                            }
                        }
                            .listRowBackground(selected == it ? Color.accentColor.opacity(0.12) : nil)
                            .contextMenu {
                                Button("자세히", systemImage: "info.circle") { detail = it }
                            }
                    }
                } else if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    ContentUnavailableView(emptyTitle, systemImage: "calendar.badge.exclamationmark",
                                           description: Text(emptyDetail))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyTitle: String {
        if settings.token.isEmpty { return "서버에 연결되어 있지 않습니다" }
        return error == nil ? "이 날 기록이 없습니다" : "불러오지 못했습니다"
    }

    private var emptyDetail: String {
        if settings.token.isEmpty { return "설정 › 서버에서 연결하면 머문 곳과 이동이 여기에 나옵니다." }
        return error ?? "자동 기록이 켜져 있으면 머문 곳과 이동이 쌓입니다."
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.headline).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 지도

    private var map: some View {
        let items = data?.items ?? []
        return AppMap(
            lines: items.filter { !$0.isVisit }.map { it in
                MapLine(coords: it.coords, color: color(it).opacity(selected == nil || selected == it ? 1 : 0.35),
                        width: selected == it ? 6 : 4, dashed: it.mode == "car" && it.drove != true)
            },
            pins: items.filter(\.isVisit).compactMap { it in
                it.center.map { MapPin(id: it.id, coord: $0, title: it.name ?? Fmt.hm(it.start), color: selected == it ? .red : .indigo,
                                      symbol: it.checkin == true ? "checkmark" : "mappin") }
            },
            fit: fitReq,
            onTapPin: { id in if let it = items.first(where: { $0.id == id }) { select(it) } })
    }

    private func color(_ it: TimelineItem) -> Color {
        switch it.mode {
        case "car": return it.drove == true ? Palette.drive : Palette.ride
        case "walk": return Palette.walk
        case "bike": return Palette.bike
        default: return .gray
        }
    }

    // MARK: 툴바

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("이전 날")
            Button { picking = true } label: { Image(systemName: "calendar") }
                .accessibilityLabel("날짜 고르기")
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("다음 날")
                .disabled(isToday)
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if !isToday { Button("오늘로", systemImage: "arrow.uturn.backward") { day = Calendar.current.startOfDay(for: Date()) } }
                Button("위치 원본 보기", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { showPoints = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("더 보기")
        }
    }

    private var datePicker: some View {
        NavigationStack {
            DatePicker("날짜", selection: Binding(get: { day }, set: { day = Calendar.current.startOfDay(for: $0); picking = false }),
                       in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("날짜 고르기")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { picking = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func shift(_ d: Int) {
        if let n = Calendar.current.date(byAdding: .day, value: d, to: day), n <= Date() { day = n }
    }

    private func select(_ it: TimelineItem) {
        if selected == it { detail = it; return }
        selected = it
        fit(it.isVisit ? (it.center.map { [$0] } ?? []) : it.coords)
    }

    // MARK: 불러오기

    private func load() async {
        selected = nil
        guard !settings.token.isEmpty else { data = nil; return }
        loading = true
        defer { loading = false }
        do {
            data = try await API.timeline(key)
            error = nil
            fit((data?.items ?? []).flatMap { $0.isVisit ? ($0.center.map { [$0] } ?? []) : $0.coords })
        } catch {
            self.error = error.localizedDescription
            data = nil
        }
    }

    /// 주차 층 고침 (nil = 추정으로 되돌림) → 서버 반영 뒤 다시 불러옴
    private func setPark(_ pk: TimelinePark, _ level: Int?) async {
        await Parking.shared.setLevel(ts: pk.ts, level: level)
        await load()
    }

    private func fit(_ cs: [CLLocationCoordinate2D]) {
        guard !cs.isEmpty else { return }
        fitReq = MapFit(key: "\(key)-\(selected?.id ?? "all")", coords: cs)
    }
}

/// 운전 끝 주차 층 표시 + 눌러서 고치기
struct ParkMenu: View {
    let park: TimelinePark
    let set: (Int?) async -> Void
    @State private var busy = false

    private static let levels = Array((-6...4).reversed())   // 5F … B6

    var body: some View {
        Menu {
            if park.est {
                Button("\(park.label) 맞아요", systemImage: "checkmark") { run(park.level) }
            }
            Section("실제 주차 층") {
                ForEach(Self.levels, id: \.self) { lv in
                    Button { run(lv) } label: {
                        if lv == park.level && !park.est { Label(ParkModel.label(lv), systemImage: "checkmark") } else { Text(ParkModel.label(lv)) }
                    }
                }
            }
            if !park.est {
                Button("추정으로 되돌리기", systemImage: "arrow.uturn.backward") { run(nil) }
            }
        } label: {
            HStack(spacing: 3) {
                if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "parkingsign.circle.fill") }
                Text(park.label).fontWeight(.semibold).monospacedDigit()
                if park.est { Text("추정").font(.caption2) }
            }
            .font(.subheadline)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(park.est ? Color.secondary : Color.white)
            .background(park.est ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.blue), in: Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("주차 \(park.label)" + (park.est ? " 추정, 눌러서 고치기" : ""))
    }

    private func run(_ lv: Int?) {
        busy = true
        Task { await set(lv); busy = false }
    }
}

/// 목록 한 줄
struct TimelineRow: View {
    let item: TimelineItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.isVisit ? "mappin.circle.fill" : item.moveSymbol)
                .font(.title3)
                .foregroundStyle(item.isVisit ? Color.indigo : tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(titleText).font(.body.weight(.semibold))
                Text(subText).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch item.mode {
        case "car": return item.drove == true ? Palette.drive : Palette.ride
        case "walk": return Palette.walk
        case "bike": return Palette.bike
        default: return .gray
        }
    }

    private var range: String {
        Fmt.hm(item.start) + "–" + (item.open == true ? "지금" : Fmt.hm(item.end))
    }

    private var titleText: String {
        item.isVisit ? (item.name ?? "머문 곳") : item.moveLabel
    }

    private var subText: String {
        if item.isVisit { return "\(range) · \(Fmt.durKo(item.durationMs))" }
        var parts = [range]
        if let km = item.km { parts.append(String(format: km < 10 ? "%.2fkm" : "%.1fkm", km)) }
        parts.append(Fmt.durKo(item.durationMs))
        if let s = item.steps, s > 0 { parts.append("\(s.formatted())걸음") }
        if item.est == true { parts.append("센서 추정 포함") }
        return parts.joined(separator: " · ")
    }
}

/// 항목 자세히 (반쯤 올라오는 시트)
struct TimelineDetailSheet: View {
    let item: TimelineItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("시각", value: Fmt.hm(item.start) + "–" + (item.open == true ? "지금" : Fmt.hm(item.end)))
                    LabeledContent("시간", value: Fmt.durKo(item.durationMs))
                    if item.isVisit {
                        if let c = item.center {
                            LabeledContent("좌표", value: String(format: "%.5f, %.5f", c.latitude, c.longitude))
                        }
                        LabeledContent("장소", value: item.name ?? "등록 안 된 곳")
                    } else {
                        LabeledContent("이동", value: item.moveLabel)
                        if let km = item.km { LabeledContent("거리", value: String(format: "%.2fkm", km)) }
                        if let s = item.steps { LabeledContent("걸음", value: s.formatted()) }
                        LabeledContent("운전 판단", value: item.drove == true ? "CarPlay 연결 — 내가 운전" : item.mode == "car" ? "CarPlay 없음 — 차량 이동" : "—")
                        if let pk = item.park {
                            LabeledContent("주차", value: pk.label + (pk.est ? " (기압 추정)" : " (확인함)"))
                        }
                        LabeledContent("경로 점", value: "\(item.coords.count)개" + (item.est == true ? " (터널 센서 추정 포함)" : ""))
                    }
                }
            }
            .navigationTitle(item.isVisit ? (item.name ?? "머문 곳") : item.moveLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
