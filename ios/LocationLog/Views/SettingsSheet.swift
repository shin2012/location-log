import SwiftUI
import CoreLocation

/// 설정 목록의 한 줄 — 서버 기록이든 이 기기 기록이든 같은 모양
struct TrackItem: Identifiable {
    let clientId: String
    let serverId: Int?
    let name: String
    let startedAt: Double
    let endedAt: Double?
    let distanceM: Double
    let nPoints: Int
    let nEst: Int
    let sentDailyAt: Double?
    let mode: TravelMode
    let recording: Bool
    let localOnly: Bool     // 서버 목록에 아직 없음 (업로드 대기 / 토큰 없음)

    var id: String { clientId }

    init(local t: LocalTrack, recording: Bool) {
        clientId = t.clientId; serverId = t.serverId; name = t.name
        startedAt = t.startedAt; endedAt = t.endedAt; distanceM = t.distanceM
        nPoints = t.points.count; nEst = 0; sentDailyAt = nil; mode = t.mode
        self.recording = recording; localOnly = true
    }

    init(server s: ServerTrack, recording: Bool) {
        clientId = s.clientId; serverId = s.id; name = s.name
        startedAt = s.startedAt ?? 0; endedAt = s.endedAt; distanceM = s.distanceM ?? 0
        nPoints = s.nPoints ?? 0; nEst = s.nEst ?? 0; sentDailyAt = s.sentDailyAt
        mode = TravelMode(rawValue: s.mode ?? "car") ?? .car
        self.recording = recording; localOnly = false
    }
}

/// 웹판 ⚙ 설정: 저장된 기록 목록 (지도 보기·이름 변경·이동 수단·데일리요섭 보내기·삭제) + 서버 연결
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: TrackStore
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toaster: Toaster
    @AppStorage("keepAwake") private var keepAwake = true
    @State private var server: [ServerTrack] = []
    @State private var loadError: String?
    @State private var loading = true
    @State private var detail: TrackItem?
    @State private var checkResult: String?
    @State private var checking = false

    private var items: [TrackItem] {
        let ids = Set(server.map(\.clientId))
        let activeId = store.active?.clientId
        let locals = store.tracks.reversed()
            .filter { !ids.contains($0.clientId) }
            .map { TrackItem(local: $0, recording: $0.clientId == activeId) }
        return locals + server.map { TrackItem(server: $0, recording: $0.clientId == activeId) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if items.isEmpty {
                        Text(loading ? "불러오는 중…" : loadError.map { "목록을 못 불러왔습니다 (\($0))" } ?? "저장된 기록이 없습니다")
                            .foregroundStyle(Palette.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                    ForEach(items) { item in
                        TrackRow(item: item, reload: reload) { detail = item }
                    }
                } header: {
                    Text("저장된 기록")
                } footer: {
                    if let e = loadError, !items.isEmpty { Text("서버 목록을 못 불러왔습니다 (\(e))") }
                }

                Section {
                    TextField("서버 주소", text: $settings.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("앱 토큰 (선택)", text: $settings.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(checking ? "확인 중…" : "연결 확인") { Task { await check() } }
                        .disabled(checking)
                    if let checkResult { Text(checkResult).font(.caption) }
                } header: {
                    Text("서버")
                } footer: {
                    Text("토큰을 비워 두면 기록은 이 기기에만 저장됩니다. 토큰을 넣으면 개인 서버와 동기화합니다.")
                }

                Section("기타") {
                    Toggle("기록 중 화면 켜 두기", isOn: $keepAwake)
                        .onChange(of: keepAwake) { _, _ in recorder.applyIdleTimer() }
                    LabeledContent("위치 권한", value: authText)
                    if recorder.authorization != .authorizedAlways {
                        Button("설정 앱에서 '항상 허용' 켜기") {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                    LabeledContent("버전", value: version)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("닫기")
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
            .onChange(of: settings.token) { _, _ in Task { await reload() } }
            .fullScreenCover(item: $detail) { item in
                RouteDetailView(item: item)
                    .environmentObject(store)
                    .preferredColorScheme(.dark)
            }
            .overlay { ToastView().environmentObject(toaster) }
        }
    }

    func reload() async {
        await store.sync()
        guard !settings.token.isEmpty else {
            server = []; loadError = nil; loading = false
            return
        }
        do {
            server = try await API.tracks()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private var authText: String {
        switch recorder.authorization {
        case .authorizedAlways: return "항상"
        case .authorizedWhenInUse: return "앱 사용 중에만"
        case .denied: return "거부됨"
        case .restricted: return "제한됨"
        case .notDetermined: return "아직 묻지 않음"
        @unknown default: return "알 수 없음"
        }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(v) (\(b))"
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            checkResult = try await API.health() ? "연결됨" : "응답 이상"
        } catch {
            checkResult = error.localizedDescription
        }
    }
}

struct TrackRow: View {
    let item: TrackItem
    let reload: () async -> Void
    let onView: () -> Void
    @EnvironmentObject var store: TrackStore
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var toaster: Toaster
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text(item.name).font(.system(size: 16, weight: .semibold)) + badges)
            Text(meta)
                .font(.system(size: 13))
                .foregroundStyle(Palette.dim)
                .monospacedDigit()
            HStack(spacing: 4) {
                ForEach(TravelMode.allCases) { m in
                    Button { Task { await setMode(m) } } label: {
                        Text("\(m.emoji) \(m.label)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(m == item.mode ? Color(red: 0.576, green: 0.773, blue: 0.992) : Palette.dim)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(m == item.mode ? Palette.blue.opacity(0.27) : Color.white.opacity(0.08),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                action("지도") { onView() }
                action("이름 변경") {
                    newName = item.name
                    renaming.toggle()
                    nameFocused = renaming
                }
                action(item.sentDailyAt != nil ? "데일리요섭 보내기 취소" : "데일리요섭 보내기",
                       disabled: item.serverId == nil || item.recording) { Task { await toggleDaily() } }
                action("삭제", destructive: true, disabled: item.recording) { confirmDelete = true }
            }
            if renaming {
                HStack(spacing: 6) {
                    TextField("이름", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { Task { await saveName() } }
                    Button("저장") { Task { await saveName() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 6)
        .confirmationDialog("\"\(item.name)\" 기록을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { Task { await delete() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("되돌릴 수 없습니다.")
        }
    }

    private var badges: Text {
        var t = Text("")
        if item.recording {
            t = t + Text("  기록 중").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(red: 0.988, green: 0.647, blue: 0.647))
        } else if item.localOnly {
            t = t + Text(store.track(item.clientId)?.serverId == nil && AppSettings.shared.token.isEmpty ? "  이 기기" : "  업로드 대기")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.dim)
        }
        if item.sentDailyAt != nil {
            t = t + Text("  보냄").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(red: 0.525, green: 0.937, blue: 0.675))
        }
        return t
    }

    private var meta: String {
        let end = item.endedAt ?? (item.recording ? Date().timeIntervalSince1970 * 1000 : nil)
        var parts = [Fmt.dateKo(item.startedAt) + " " + Fmt.hm(item.startedAt) + (end.map { "–" + Fmt.hm($0) } ?? "")]
        if item.distanceM > 0 { parts.append(String(format: "%.1fkm", item.distanceM / 1000)) }
        if let end { parts.append(Fmt.durKo(end - item.startedAt)) }
        if item.nPoints > 0 { parts.append("\(item.nPoints.formatted())점" + (item.nEst > 0 ? " (추정 \(item.nEst))" : "")) }
        return parts.joined(separator: " · ")
    }

    private func action(_ title: String, destructive: Bool = false, disabled: Bool = false,
                        _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(destructive ? Color(red: 0.988, green: 0.647, blue: 0.647) : .white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func setMode(_ m: TravelMode) async {
        guard m != item.mode else { return }
        do {
            if let sid = item.serverId, !AppSettings.shared.token.isEmpty {
                _ = try await API.patch(sid, PatchBody(mode: m.rawValue))
            }
            if item.recording { recorder.mode = m } else { store.setMode(m, for: item.clientId) }
            toaster.show("\(m.emoji) \(m.label)(으)로 변경")
            await reload()
        } catch {
            toaster.show("변경 실패: \(error.localizedDescription)")
        }
    }

    private func saveName() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            if let sid = item.serverId, !AppSettings.shared.token.isEmpty {
                _ = try await API.patch(sid, PatchBody(name: name))
            }
            if store.track(item.clientId) != nil { store.rename(item.clientId, to: name) }
            renaming = false
            toaster.show("이름을 바꿨습니다")
            await reload()
        } catch {
            toaster.show("이름 변경 실패: \(error.localizedDescription)")
        }
    }

    private func toggleDaily() async {
        guard let sid = item.serverId else { return }
        do {
            if item.sentDailyAt != nil {
                _ = try await API.sendDaily(sid, false)
                toaster.show("데일리요섭에서 뺐습니다")
            } else {
                _ = try await API.sendDaily(sid, true)
                toaster.show("데일리요섭으로 보냈습니다. 그날 지도에 실제 경로로 나옵니다")
            }
            await reload()
        } catch {
            toaster.show("실패: \(error.localizedDescription)")
        }
    }

    private func delete() async {
        do {
            if let sid = item.serverId, !AppSettings.shared.token.isEmpty { try await API.delete(sid) }
            store.removeLocal(item.clientId)
            toaster.show("삭제했습니다")
            await reload()
        } catch {
            toaster.show("삭제 실패: \(error.localizedDescription)")
        }
    }
}
