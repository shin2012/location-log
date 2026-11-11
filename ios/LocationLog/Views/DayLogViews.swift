import SwiftUI
import MapKit
import CoreLocation
import CoreMotion

/// 설정 탭 (Form 묶음): 상태 요약 · 기록 · 서버 · 권한 · 정보
struct SettingsScreen: View {
    @EnvironmentObject var recorder: Recorder
    @ObservedObject private var logger = DayLogger.shared
    @ObservedObject private var store = DayLogger.shared.store
    @ObservedObject private var settings = DaySettings.shared
    @ObservedObject private var carplay = CarPlayWatcher.shared
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("mapProvider") private var mapProvider: MapProvider = .naver
    @ObservedObject private var maps = MapServices.shared
    @State private var shotDayMap: String?    // CI 화면 캡처용 (Debug): 실행 인자 -shotDayMap YYYY-MM-DD → 날짜별 위치 원본 지도로 바로 넘어감
    @State private var shotPre: ([DayPoint], [DayVisitRec])?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("자동 기록", value: logger.running ? logger.statusText : "꺼짐")
                    if logger.running {
                        LabeledContent("오늘 GPS 사용", value: Fmt.durKo(logger.gpsSecondsToday * 1000))
                        LabeledContent("서버 대기", value: AppSettings.shared.token.isEmpty ? "이 기기에만 저장" : "\(store.pendingCount.formatted())건")
                        if let u = store.lastUploadAt { LabeledContent("마지막 업로드", value: Fmt.hm(u.timeIntervalSince1970 * 1000)) }
                    }
                } header: { Text("지금") }

                Section {
                    NavigationLink { AutoRecordSettingsView() } label: {
                        LabeledContent { Text(settings.prefs.enabled ? "켜짐" : "꺼짐") } label: { Label("자동 기록", systemImage: "location.circle") }
                    }
                    NavigationLink { BatterySettingsView() } label: { Label("배터리", systemImage: "battery.75percent") }
                    NavigationLink { DriveSettingsView() } label: {
                        LabeledContent { Text(carplay.connected ? "연결됨" : "") } label: { Label("운전·CarPlay", systemImage: "car") }
                    }
                    NavigationLink { QuietSettingsView() } label: { Label("쉬는 시간·제외 장소", systemImage: "moon") }
                    Toggle(isOn: $keepAwake) { Label("경로 기록 중 화면 켜 두기", systemImage: "sun.max") }
                        .onChange(of: keepAwake) { _, _ in recorder.applyIdleTimer() }
                } header: { Text("기록") }

                Section {
                    Picker(selection: $mapProvider) {
                        ForEach(MapProvider.allCases) { Text($0.label).tag($0) }
                    } label: { Label("지도", systemImage: "map") }
                    if mapProvider == .naver && maps.naverFailed {
                        Text("네이버 지도 인증 실패 — 구글 지도로 보여 줍니다 (\(maps.naverError ?? ""))").font(.footnote).foregroundStyle(.orange)
                    }
                } header: { Text("화면") } footer: {
                    Text("네이버는 국내에서만 쓰고, 국외 지역이거나 네이버가 안 되면 구글 지도로 바꿔 보여 줍니다.")
                }

                Section {
                    ServerConnectionRow()
                    NavigationLink { UploadSettingsView() } label: { Label("올리기·보관", systemImage: "icloud.and.arrow.up") }
                } header: { Text("서버") }

                Section {
                    LabeledContent("위치", value: locationAuth)
                    LabeledContent("동작 및 피트니스", value: motionAuth)
                    if logger.authorization != .authorizedAlways || CMMotionActivityManager.authorizationStatus() != .authorized {
                        Button("설정 앱에서 권한 바꾸기") {
                            if logger.authorization == .notDetermined { logger.requestPermission() }
                            else if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                } header: { Text("권한") } footer: {
                    Text("자동 기록·자동 체크인은 위치 '항상 허용'이, 이동 방식·걸음은 '동작 및 피트니스'가 필요합니다.")
                }

                Section("정보") {
                    LabeledContent("버전", value: version)
                }
            }
            .navigationTitle("설정")
            #if DEBUG
            .navigationDestination(isPresented: Binding(get: { shotDayMap != nil }, set: { if !$0 { shotDayMap = nil } })) {
                if let pre = shotPre { DayMapView(day: shotDayMap ?? "", points: pre.0, visits: pre.1) }
                else { DayMapView(day: shotDayMap ?? "") }
            }
            .task {
                if let d = UserDefaults.standard.string(forKey: "shotDayMap"), !d.isEmpty {
                    // -shotPreload YES: 점을 먼저 받아 두고 넘어감 (기기에 저장된 날처럼 첫 화면부터 경로 있음)
                    if UserDefaults.standard.bool(forKey: "shotPreload"), let x = try? await API.day(d) { shotPre = (x.points, x.visits) }
                    try? await Task.sleep(for: .milliseconds(800))
                    shotDayMap = d
                }
            }
            #endif
        }
    }

    private var locationAuth: String {
        switch logger.authorization {
        case .authorizedAlways: return "항상"
        case .authorizedWhenInUse: return "앱 사용 중에만"
        case .denied: return "거부됨"
        case .restricted: return "제한됨"
        case .notDetermined: return "아직 묻지 않음"
        @unknown default: return "알 수 없음"
        }
    }

    private var motionAuth: String {
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: return "허용"
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
}

/// 설정 › 자동 기록 (예전 '하루 종일 기록')
struct AutoRecordSettingsView: View {
    @ObservedObject var logger = DayLogger.shared
    @ObservedObject var settings = DaySettings.shared
    @ObservedObject var store = DayLogger.shared.store
    @ObservedObject var motion = MotionHistory.shared
    private var p: Binding<DayPrefs> { $settings.prefs }

    var body: some View {
        Form {
            Section {
                Toggle("자동 기록", isOn: p.enabled)
                if settings.prefs.enabled {
                    LabeledContent("상태", value: logger.statusText)
                    LabeledContent("오늘 저장", value: "\(store.count(today).formatted())점")
                    if let e = store.lastError { Text(e).font(.footnote).foregroundStyle(.orange) }
                    if let u = motion.lastUploadAt { LabeledContent("이동 방식·걸음 업로드", value: Fmt.hm(u.timeIntervalSince1970 * 1000)) }
                    if let e = motion.lastError { Text(e).font(.footnote).foregroundStyle(.orange) }
                }
            } footer: {
                Text("'기록 시작'을 누르지 않아도 하루 내내 위치를 저장합니다. 머무는 동안은 GPS를 꺼 두고, 움직이기 시작하면 켭니다. 이동 방식(걷기·차·자전거)과 1분 걸음도 함께 올립니다(iOS는 7일치만 보관). 앱을 위로 쓸어 강제로 끄면 다시 열 때까지 멈출 수 있습니다.")
            }

            Section {
                Picker("움직일 때 정확도", selection: p.level) {
                    ForEach(DayLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { Text("움직일 때 정확도") } footer: {
                Text(settings.prefs.level.detail + (logger.lowBattery && settings.prefs.lowPowerSave ? "\n지금은 배터리가 부족해 '절약'으로 동작 중" : ""))
            }

            Section {
                Toggle("앱 깨워 두기 (저정확도 위치)", isOn: p.keepAlive)
                Toggle("움직임 감지로 출발 알아채기", isOn: p.motionWake)
                    .disabled(!settings.prefs.keepAlive)
                Picker("머무는 동안 GPS 확인", selection: p.checkMinutes) {
                    Text("끔").tag(0)
                    Text("5분마다").tag(5)
                    Text("10분마다").tag(10)
                    Text("15분마다").tag(15)
                    Text("30분마다").tag(30)
                }
                .disabled(!settings.prefs.keepAlive)
                Toggle("출발 구간 메우기", isOn: p.fillGap)
                Toggle("경계·방문 감지 (앱이 꺼졌을 때 깨우기)", isOn: p.regionWake)
            } header: { Text("출발 알아채기") } footer: {
                Text("머무는 동안 GPS 대신 기지국·와이파이 위치로 앱만 깨워 둡니다(소모 적음). 이게 켜져 있어야 움직임 감지·GPS 확인이 동작합니다. 출발 구간 메우기는 머물던 자리에서 첫 GPS 위치까지를 출발 시각으로 이어 줍니다. 모두 끄면 경계·방문 감지(100~200m)로만 출발을 알아챕니다.")
            }

            Section("세부") {
                Picker("머묾 판정 시간", selection: p.stayMinutes) {
                    ForEach([3, 5, 10, 15], id: \.self) { Text("\($0)분").tag($0) }
                }
                Picker("머묾 반경", selection: p.stayRadius) {
                    ForEach([50.0, 100, 150, 200], id: \.self) { Text("\(Int($0))m").tag($0) }
                }
                Picker("경계 반경", selection: p.geofenceRadius) {
                    ForEach([100.0, 150, 200, 300], id: \.self) { Text("\(Int($0))m").tag($0) }
                }
                Picker("움직일 때 저장 간격", selection: p.movingDistance) {
                    Text("자동").tag(0.0)
                    ForEach([10.0, 20, 50, 100, 200], id: \.self) { Text("\(Int($0))m").tag($0) }
                }
            }

            Section {
                NavigationLink("날짜별 위치 원본") { DayHistoryView() }
            }
        }
        .navigationTitle("자동 기록")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var today: String { DayLogStore.dayKey(Date().timeIntervalSince1970 * 1000) }
}

/// 설정 › 배터리
struct BatterySettingsView: View {
    @ObservedObject var logger = DayLogger.shared
    @ObservedObject var settings = DaySettings.shared
    private var p: Binding<DayPrefs> { $settings.prefs }

    var body: some View {
        Form {
            Section {
                LabeledContent("지금", value: now)
                Toggle("저전력 모드·배터리 20% 이하면 절약", isOn: p.lowPowerSave)
                Toggle("충전 중이면 정밀하게", isOn: p.chargePrecise)
                Toggle("상단 위치 사용 표시", isOn: p.showIndicator)
            } footer: {
                Text("절약으로 바뀌면 움직일 때 정확도를 낮추고 머무는 동안 GPS 확인을 멈춥니다. 충전 중에는 움직일 때 '정밀', 머무는 동안 3분마다 확인합니다. 폰이 뜨거우면 충전 중 정밀을 멈춥니다.")
            }
        }
        .navigationTitle("배터리")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var now: String {
        var parts: [String] = []
        if logger.charging { parts.append("충전 중") }
        if logger.lowBattery { parts.append("배터리 부족") }
        if logger.hot { parts.append("발열 심각 — 정밀도 한 단계 낮춤") }
        return parts.isEmpty ? "보통" : parts.joined(separator: " · ")
    }
}

/// 설정 › 운전·CarPlay
struct DriveSettingsView: View {
    @ObservedObject var logger = DayLogger.shared
    @ObservedObject var settings = DaySettings.shared
    @ObservedObject var carplay = CarPlayWatcher.shared
    @ObservedObject var cpEvents = CarPlayEvents.shared
    @ObservedObject var parking = Parking.shared
    @ObservedObject var baro = Baro.shared
    @ObservedObject var wifi = WifiLog.shared
    @ObservedObject var health = HealthHistory.shared
    private var p: Binding<DayPrefs> { $settings.prefs }

    var body: some View {
        Form {
            Section {
                Toggle("차로 이동 + 충전 중이면 1초 기록", isOn: p.driveRecord)
                if logger.autoDriving {
                    LabeledContent("지금", value: logger.driveLock ? "1초 기록 중 · 운전 끝까지 고정" : "1초 기록 중")
                }
            } footer: {
                Text("차로 이동(CarPlay 연결 또는 차량 움직임)하며 충전 중이면 1초마다 위치를 받아 하루 기록(타임라인)에 저장하고, 터널처럼 GPS가 끊기면 센서로 이어 그립니다. 경로 기록 메뉴에는 저장하지 않습니다. CarPlay 연결과 충전이 한 번이라도 확인되면 충전이 끊겨도 CarPlay 해제 1분 뒤까지 1초 기록을 유지합니다. CarPlay 없이 차로 움직이면 내려서 3분 뒤 끕니다. 폰이 뜨거우면(iOS 발열 단계 심각 이상) 정밀도만 한 단계 낮춥니다.")
            }
            Section {
                Toggle("CarPlay 연결 기록 보내기", isOn: p.carplaySend)
                LabeledContent("상태", value: (carplay.connected ? "연결됨" : "연결 안 됨") + (carplay.viaShortcut ? " · 단축어" : " · 소리 출력 경로로 짐작"))
                if !cpEvents.pending.isEmpty { LabeledContent("보낼 기록", value: "\(cpEvents.pending.count)건") }
                if let e = cpEvents.lastError { Text(e).font(.footnote).foregroundStyle(.orange) }
            } header: { Text("CarPlay") } footer: {
                Text("CarPlay에 연결되면 '내가 운전', 연결 없이 차로 움직이면 '차량 이동'으로 구분합니다.")
            }
            Section {
                Toggle("주차 층 알림", isOn: p.parkNotify)
                LabeledContent("기압계", value: !Baro.available ? "이 기기에 없음"
                               : baro.latest.map { String(format: "%.1f hPa", $0.kpa * 10) } ?? (logger.running ? "기다리는 중" : "하루 기록 꺼짐"))
                if let l = parking.lastPark {
                    LabeledContent("마지막 주차", value: "\(ParkModel.label(l.level)) · 도로 대비 \(String(format: "%+.1f", l.dh))m · \(Fmt.hm(l.ts))")
                }
                Toggle("워치 걸음·계단 (건강 앱)", isOn: p.watchHealth)
                    .onChange(of: settings.prefs.watchHealth) { _, on in if on { HealthHistory.shared.requestPermission() } }
                if settings.prefs.watchHealth {
                    LabeledContent("건강 앱", value: !HealthHistory.available ? "이 기기에 없음"
                                   : health.lastUploadAt.map { "올림 " + Fmt.hm($0.timeIntervalSince1970 * 1000) + " · 새 기록 \(health.lastCount)개" } ?? "아직 안 올림")
                }
                LabeledContent("연결 공유기", value: wifi.current?.bssid.map { (wifi.current?.ssid ?? "") + " · " + $0 } ?? "없음")
                if let e = parking.lastError ?? baro.lastError ?? wifi.lastError ?? health.lastError { Text(e).font(.footnote).foregroundStyle(.orange) }
            } header: { Text("주차 층 · 층 이동") } footer: {
                Text("CarPlay 연결이 끊기면(주차) 마지막으로 도로를 달리던 곳과 지금의 기압 차로 몇 층인지 추정해 1분 뒤 알려 줍니다(1분 안에 다시 연결되면 취소). 알림을 길게 눌러 '한 층 위·아래'로 고치거나 타임라인에서 층을 누르면, 그 주차장(150m 안)의 층 높이를 배워 다음부터 맞춥니다. 기압은 하루 기록이 켜져 있는 동안 계속 저장해, 머문 곳 안에서 엘리베이터·계단으로 층을 옮기면 타임라인에 층 구간으로 보여 줍니다. 연결된 공유기 고유번호는 층 확인용 보조로만 씁니다(같은 공유기에서 두 번 이상 같은 층으로 확정했을 때). 폰을 두고 다닐 때는 Apple Watch가 건강 앱에 남긴 계단으로 오른 층수로 층 이동만 추정합니다(엘리베이터·내린 층은 워치가 세지 않음).")
            }
            Section {
                Label("단축어 앱 › 자동화 › 새로운 자동화 › CarPlay", systemImage: "1.circle")
                Label("'연결 시' › 동작 '시야쥬 › CarPlay 연결 기록하기'", systemImage: "2.circle")
                Label("'연결 해제 시' › 동작 '시야쥬 › CarPlay 연결 해제 기록하기'", systemImage: "3.circle")
                Label("두 자동화 모두 '즉시 실행'", systemImage: "4.circle")
            } header: { Text("단축어 설정 (가장 정확)") } footer: {
                Text("한 번 받으면 그 뒤로는 단축어 신호만 씁니다. 설정 전에는 소리 출력 경로로 짐작합니다.")
            }
        }
        .navigationTitle("운전·CarPlay")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 설정 › 쉬는 시간·제외 장소
struct QuietSettingsView: View {
    @ObservedObject var logger = DayLogger.shared
    @ObservedObject var settings = DaySettings.shared
    @EnvironmentObject var toaster: Toaster
    @State private var newPlaceName = ""
    private var p: Binding<DayPrefs> { $settings.prefs }

    var body: some View {
        Form {
            Section {
                Toggle("쉬는 시간", isOn: p.quietOn)
                if settings.prefs.quietOn {
                    Picker("시작", selection: p.quietStart) { ForEach(0..<24, id: \.self) { Text("\($0)시").tag($0) } }
                    Picker("끝", selection: p.quietEnd) { ForEach(0..<24, id: \.self) { Text("\($0)시").tag($0) } }
                }
            } header: { Text("기록 안 할 시간") } footer: {
                Text("이 시간에는 저장하지 않고 GPS도 켜지 않습니다.")
            }
            Section {
                ForEach(settings.prefs.excluded) { pl in
                    LabeledContent(pl.name, value: "반경 \(Int(pl.radius))m")
                }
                .onDelete { settings.prefs.excluded.remove(atOffsets: $0) }
                HStack {
                    TextField("이름 (예: 집)", text: $newPlaceName)
                    Button("지금 위치 추가") { addPlace() }
                        .buttonStyle(.borderless)
                }
            } header: { Text("기록 안 할 장소") } footer: {
                Text("이 장소 반경 150m 안의 위치·머문 곳은 저장하지 않습니다. 밀어서 지울 수 있습니다.")
            }
        }
        .navigationTitle("쉬는 시간·제외 장소")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addPlace() {
        guard let l = logger.currentLocation(), l.horizontalAccuracy >= 0, l.horizontalAccuracy < 200 else {
            toaster.show("지금 위치를 아직 모릅니다")
            return
        }
        let name = newPlaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.prefs.excluded.append(.init(name: name.isEmpty ? "장소 \(settings.prefs.excluded.count + 1)" : name,
                                             lat: l.coordinate.latitude, lon: l.coordinate.longitude))
        newPlaceName = ""
        toaster.show("추가했습니다")
    }
}

/// 설정 › 서버 › 올리기·보관
struct UploadSettingsView: View {
    @ObservedObject var logger = DayLogger.shared
    @ObservedObject var settings = DaySettings.shared
    @ObservedObject var store = DayLogger.shared.store
    @EnvironmentObject var toaster: Toaster
    private var p: Binding<DayPrefs> { $settings.prefs }

    var body: some View {
        Form {
            Section {
                Picker("올리는 간격", selection: p.uploadMinutes) {
                    ForEach([1, 5, 15, 30, 60, 180], id: \.self) { Text($0 < 60 ? "\($0)분" : "\($0 / 60)시간").tag($0) }
                }
                Toggle("Wi-Fi에서만 올리기", isOn: p.wifiOnly)
                Button("지금 올리기") {
                    Task {
                        await logger.upload(force: true)
                        toaster.show(store.lastError.map { "실패: \($0)" } ?? "올렸습니다")
                    }
                }
                .disabled(AppSettings.shared.token.isEmpty)
                Picker("이 기기 보관", selection: p.keepDays) {
                    ForEach([30, 90, 365], id: \.self) { Text("\($0)일").tag($0) }
                    Text("무제한").tag(0)
                }
            } footer: {
                Text("점마다 보내지 않고 모아서 올립니다(통신도 배터리를 씀). 간격이 짧을수록 서버에 빨리 반영되지만 배터리를 조금 더 씁니다 — 앱이 백그라운드에서 깨어 있을 때만 그 간격대로 올라갑니다. 서버에 올라간 위치 기록만 보관 기간이 지나면 이 기기에서 지웁니다(무제한이면 지우지 않음). 이동 방식·걸음·기압·공유기·워치·CarPlay·주차·고친 기록은 날짜별로 앱 안에 계속 보관해, 다른 앱(iOS 동작 기록은 7일만 보관)이나 서버에서 원본이 없어져도 남습니다.")
            }
        }
        .navigationTitle("올리기·보관")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 서버 연결: 연결돼 있으면 상태만, '수정'을 누르면 시트에서 주소·토큰 입력
struct ServerConnectionRow: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toaster: Toaster
    @State private var editing = false
    @State private var ok: Bool?
    @State private var detail = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: settings.token.isEmpty ? "iphone" : ok == false ? "exclamationmark.icloud" : "checkmark.icloud")
                .foregroundStyle(settings.token.isEmpty ? Color.secondary : ok == false ? Color.red : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.token.isEmpty ? "연결 안 함" : ok == nil ? "확인 중…" : ok == true ? "연결됨" : "연결 안 됨")
                Text(settings.token.isEmpty ? "기록은 이 기기에만 저장됩니다" : detail.isEmpty ? host : detail)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(settings.token.isEmpty ? "연결" : "수정") { editing = true }
                .buttonStyle(.borderless)
        }
        .task(id: settings.token) { await check() }
        .sheet(isPresented: $editing) { ServerEditSheet { await check() } }
    }

    private var host: String { URL(string: settings.baseURL)?.host ?? settings.baseURL }

    private func check() async {
        guard !settings.token.isEmpty else { ok = nil; return }
        ok = nil
        do { _ = try await API.days(); ok = true; detail = "" } catch { ok = false; detail = error.localizedDescription }
    }
}

struct ServerEditSheet: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toaster: Toaster
    @Environment(\.dismiss) private var dismiss
    let onSaved: () async -> Void
    @State private var url = ""
    @State private var token = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("서버 주소", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("앱 토큰 (비우면 이 기기에만 저장)", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text(error ?? "토큰을 비워 두면 기록은 이 기기에만 저장됩니다. 토큰을 넣으면 개인 서버와 동기화합니다.")
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("서버")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(checking ? "확인 중…" : "저장") { Task { await save() } }.disabled(checking)
                }
            }
            .onAppear { url = settings.baseURL; token = settings.token }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        checking = true
        defer { checking = false }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.baseURL = u.isEmpty ? AppSettings.defaultBaseURL : u
        settings.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !settings.token.isEmpty {
            do { _ = try await API.days() } catch { self.error = error.localizedDescription; return }
        }
        await onSaved()
        toaster.show(settings.token.isEmpty ? "이 기기에만 저장합니다" : "서버에 연결됨")
        dismiss()
    }
}

/// 하루 기록 날짜 목록 (이 기기 + 서버)
struct DayHistoryView: View {
    @ObservedObject var store = DayLogger.shared.store
    @State private var server: [ServerDay] = []
    @State private var error: String?

    private var rows: [(day: String, n: Int)] {
        var m: [String: Int] = [:]
        for s in server { m[s.date] = s.nPoints }
        for d in store.days() { m[d] = max(m[d] ?? 0, store.count(d)) }
        return m.map { ($0.key, $0.value) }.sorted { $0.day > $1.day }
    }

    var body: some View {
        List {
            if rows.isEmpty {
                Text(error.map { "서버 목록을 못 불러왔습니다 (\($0))" } ?? "아직 기록이 없습니다")
                    .foregroundStyle(Palette.dim)
            }
            ForEach(rows, id: \.day) { r in
                NavigationLink {
                    DayMapView(day: r.day)
                } label: {
                    LabeledContent(r.day, value: "\(r.n.formatted())점")
                }
            }
        }
        .navigationTitle("날짜별 위치 원본")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !AppSettings.shared.token.isEmpty else { return }
        do { server = try await API.days(); error = nil } catch { self.error = error.localizedDescription }
    }
}

/// 하루 지도: 경로 + 머문 곳
struct DayMapView: View {
    let day: String
    @ObservedObject var store = DayLogger.shared.store
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var toaster: Toaster
    @State private var points: [DayPoint] = []
    @State private var visits: [DayVisitRec] = []

    init(day: String) { self.day = day }

    /// 점을 미리 넣고 시작 (첫 화면부터 경로가 있는 경우 = 이 기기에 저장된 날과 같은 상황; CI 캡처용)
    init(day: String, points: [DayPoint], visits: [DayVisitRec]) {
        self.day = day
        _points = State(initialValue: points)
        _visits = State(initialValue: visits)
    }
    @State private var info = "불러오는 중…"
    @State private var confirmDelete = false

    /// 지도 그리기용: 메운 구간은 점선(추정과 같은 모양)
    private var trackPoints: [TrackPoint] {
        points.enumerated().map { i, p in
            TrackPoint(seq: i, ts: p.ts, lat: p.lat, lon: p.lon, alt: p.alt, acc: p.acc, spd: p.spd, hdg: nil,
                       src: p.src == "fill" ? "imu" : "gps", brk: nil)
        }
    }

    var body: some View {
        // 머문 곳 = 보라 핀(머문 시각), 선 = 저장된 위치 점을 이은 것 (주황 점선 = 출발 구간 메움)
        AppMap(lines: TrackGeometry.runs(trackPoints).map { MapLine(coords: $0.coords, color: $0.est ? Palette.warn : Palette.route, dashed: $0.est) },
               pins: visits.map { v in MapPin(id: "\(v.arrive)", coord: .init(latitude: v.lat, longitude: v.lon),
                                              title: "머묾 " + visitLabel(v), color: .purple) },
               fit: points.isEmpty ? nil : MapFit(key: "\(day)-\(points.count)", coords: points.map { .init(latitude: $0.lat, longitude: $0.lon) }))
        .safeAreaInset(edge: .bottom) {
            Text(info)
                .font(.system(size: 13))
                .foregroundStyle(Palette.dim)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Palette.bg)
        }
        .navigationTitle("위치 원본 · " + day)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel("이 날 기록 삭제")
            }
        }
        .confirmationDialog("\(day) 하루 기록을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { Task { await delete() } }
            Button("취소", role: .cancel) {}
        } message: { Text("이 기기와 서버에서 모두 지웁니다. 되돌릴 수 없습니다.") }
        .task { await load() }
    }

    private func visitLabel(_ v: DayVisitRec) -> String {
        Fmt.hm(v.arrive) + "–" + (v.depart.map { Fmt.hm($0) } ?? "")
    }

    private func load() async {
        let local = store.points(day)
        if !points.isEmpty {
            // 미리 받은 점 그대로
        } else if !local.isEmpty {
            points = local
            visits = store.visits(day)
        } else if !AppSettings.shared.token.isEmpty {
            do {
                let d = try await API.day(day)
                points = d.points
                visits = d.visits
            } catch {
                info = "불러오기 실패: \(error.localizedDescription)"
                return
            }
        }
        let km = TrackGeometry.distance(trackPoints) / 1000
        info = points.isEmpty ? "점이 없습니다"
            : "\(points.count.formatted())점 · \(String(format: "%.1f", km))km · 머문 곳 \(visits.count)곳"
        fit()
    }

    private func delete() async {
        do {
            if !AppSettings.shared.token.isEmpty { try await API.deleteDay(day) }
            store.delete(day)
            toaster.show("삭제했습니다")
            dismiss()
        } catch {
            toaster.show("삭제 실패: \(error.localizedDescription)")
        }
    }

    private func fit() {}   // AppMap 이 fit 키로 맞춤

}

extension DayPoint {
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
