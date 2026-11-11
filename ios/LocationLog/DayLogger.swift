import Foundation
import CoreLocation
import CoreMotion
import UIKit

/// 하루 종일 기록. '기록 시작'과 별개로 켜 두면 하루 내내 위치를 저장.
///
/// 배터리: 머무는 동안은 GPS를 끄고 저정확도 위치(기지국·와이파이)로 앱만 깨워 둔다.
/// 출발은 ① 움직임 감지 칩 ② 주기 GPS 확인 ③ 저정확도 위치 변화 ④ 경계·방문·기지국 변화(앱이 꺼졌을 때)로 알아채고,
/// 그때만 이동 수단에 맞춘 GPS를 켠다. 판단은 DayPolicy(순수 로직)가 한다.
@MainActor
final class DayLogger: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = DayLogger()

    @Published private(set) var phase: DayPolicy.Phase = .moving
    @Published private(set) var activity: DayActivity = .unknown
    @Published private(set) var running = false
    @Published private(set) var quiet = false
    @Published private(set) var lowBattery = false
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastFixAt: Date?
    @Published private(set) var gpsSecondsToday: Double = 0
    @Published private(set) var config: DayGPSConfig = .off
    @Published private(set) var charging = false
    @Published private(set) var hot = false                 // iOS 발열 단계 serious 이상 → 정밀도만 한 단계 낮춤 (기록은 그대로)
    @Published private(set) var autoDriving = false         // 차 + 충전 중이라 1초 기록을 자동으로 켬 (하루 기록에만 저장)
    @Published private(set) var driveLock = false           // 이번 운전에서 CarPlay + 충전 확인 → 운전 끝까지 1초 정밀도 고정

    let store = DayLogStore()
    let settings = DaySettings.shared
    private let manager = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private var policy: DayPolicy
    private var tickTimer: Timer?
    private var quietTimer: Timer?
    private var bgSession: CLBackgroundActivitySession?
    private var motionOn = false
    private var regionCenter: CLLocationCoordinate2D?
    private var slcOn = false
    private var recorderOn = false          // Recorder 1초 엔진이 켜져 있음(경로 기록 또는 자동 운전) → 그 점을 받아 씀
    private var gpsSince: Date?
    private var lastUploadTry = Date.distantPast
    private var booted = false
    private weak var recorder: Recorder?
    private var autoTimer: Timer?
    private static let stateKey = "day.state"
    private static let autoKey = "day.autoDriving"      // 1.2.x — 이어받기만
    private static let gateKey = "day.driveGate"
    private var gate = DriveGate()
    private static let regionId = "day.stay"

    private override init() {
        var st = DayPolicy.State()
        if let d = UserDefaults.standard.data(forKey: Self.stateKey),
           let s = try? JSONDecoder().decode(DayPolicy.State.self, from: d) { st = s }
        policy = DayPolicy(options: DaySettings.shared.prefs.policyOptions(lowBattery: false), state: st)
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false   // 멈추면 앱이 잠들어 다시 못 깨움
        authorization = manager.authorizationStatus
    }

    /// 앱 시작 때 (백그라운드로 다시 켜진 경우 포함) 한 번
    func boot(recorder: Recorder) {
        guard !booted else { return }
        booted = true
        recorder.onFix = { [weak self] l in self?.ingestRecorderFix(l) }
        recorder.onEngineChanged = { [weak self] on in self?.setRecorderOn(on) }
        recorder.onEstimate = { [weak self] p in self?.ingestEstimate(p) }
        self.recorder = recorder
        recorderOn = recorder.engineOn
        // 앱이 꺼졌다 켜졌는데 자동 운전 중이었으면 이어서 (조건이 풀렸으면 evaluateDrive 가 정리)
        if let d = UserDefaults.standard.data(forKey: Self.gateKey), let g = try? JSONDecoder().decode(DriveGate.self, from: d) {
            gate = g
        } else if UserDefaults.standard.bool(forKey: Self.autoKey) {
            gate.driving = true
        }
        UserDefaults.standard.removeObject(forKey: Self.autoKey)
        publishGate()
        if gate.driving { recorder.startAuto() }
        CarPlayWatcher.shared.onChange = { [weak self] on in self?.carPlayChanged(on) }
        CarPlayWatcher.shared.start()
        settings.onChange = { [weak self] old in self?.prefsChanged(old) }
        // 자동 체크인: 장소 반경 진입·이탈 (하루 종일 기록이 꺼져 있어도 동작)
        AutoCheckin.shared.onChange = { [weak self] in
            guard let self else { return }
            AutoCheckin.shared.apply(self.manager)
        }
        AutoCheckin.shared.apply(manager)
        Task {
            await AutoCheckin.shared.refreshPlaces()
            await AutoCheckin.shared.flush()
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let nc = NotificationCenter.default
        for n in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                  Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshBattery() }
            }
        }
        refreshBattery(apply: false)
        loadGPSStat()
        if settings.prefs.enabled {
            store.prune(keepDays: settings.prefs.keepDays)
            start()
            // 다시 켜졌으면 지금 자리가 맞는지 한 번 확인
            handle(policy.nudge(now()))
        }
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    // MARK: 켜고 끄기

    private func start() {
        running = true
        requestPermission()
        if CMMotionActivityManager.isActivityAvailable() {
            // 움직임 감지는 앱이 깨어 있어야 받음. 꺼도(motionWake=false) 이동 수단 구분에는 씀
            if !motionOn {
                motionOn = true
                motion.startActivityUpdates(to: .main) { [weak self] a in
                    guard let self, let a else { return }
                    MainActor.assumeIsolated { self.onActivity(a) }
                }
            }
        }
        Baro.shared.start()
        WifiLog.shared.start()
        apply()
        scheduleTick()
    }

    private func stop() {
        running = false
        tickTimer?.invalidate(); tickTimer = nil
        quietTimer?.invalidate(); quietTimer = nil
        if motionOn { motion.stopActivityUpdates(); motionOn = false }
        manager.stopUpdatingLocation()
        if slcOn { manager.stopMonitoringSignificantLocationChanges(); manager.stopMonitoringVisits(); slcOn = false }
        removeRegion()
        bgSession?.invalidate(); bgSession = nil
        manager.allowsBackgroundLocationUpdates = false
        accumulateGPS(on: false)
        config = .off
        store.flush()
        Baro.shared.stop()
        WifiLog.shared.stop()
    }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    private func prefsChanged(_ old: DayPrefs) {
        let p = settings.prefs
        policy.opt = p.policyOptions(lowBattery: lowBattery, boost: charging)
        evaluateDrive()
        if p.enabled && !running {
            store.prune(keepDays: p.keepDays)
            start()
            handle(policy.nudge(now()))
        } else if !p.enabled && running {
            stop()
            Task { await store.upload(wifiOnly: false); await MotionHistory.shared.upload(wifiOnly: false) }
        } else if running {
            lastApplied = nil
            apply()
            scheduleTick()
        }
    }

    private func refreshBattery(apply doApply: Bool = true) {
        let d = UIDevice.current
        let ch = d.batteryState == .charging || d.batteryState == .full
        let th = ProcessInfo.processInfo.thermalState
        let h = th == .serious || th == .critical
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled || (!ch && d.batteryLevel >= 0 && d.batteryLevel <= 0.2)
        guard low != lowBattery || ch != charging || h != hot || !doApply else { return }
        lowBattery = low
        charging = ch
        hot = h
        policy.opt = settings.prefs.policyOptions(lowBattery: low, boost: ch)
        recorder?.reducedAccuracy = h
        if doApply && running { lastApplied = nil; apply(); scheduleTick() }
        if doApply { evaluateDrive() }
    }

    private func setRecorderOn(_ on: Bool) {
        recorderOn = on
        if running { lastApplied = nil; apply(); scheduleTick() }
    }

    /// 앱이 앞/뒤로 갈 때
    func setForeground(_ on: Bool) {
        if on {
            refreshBattery()
            if running && settings.prefs.parkNotify && settings.prefs.driveRecord { Parking.shared.requestPermission() }
            if running && settings.prefs.watchHealth { HealthHistory.shared.requestPermission() }
            Task { await upload(force: true) }
        } else {
            store.flush()
            persist()
        }
    }

    // MARK: 위치 관리자 적용

    private var lastApplied: (DayGPSConfig, DayActivity, Bool)?

    private func apply() {
        guard running else { return }
        let p = settings.prefs
        let a = manager.authorizationStatus
        guard a == .authorizedAlways || a == .authorizedWhenInUse else { return }

        let q = p.isQuiet(Date())
        if q != quiet { quiet = q }
        scheduleQuietTimer()

        var c: DayGPSConfig
        if recorderOn {
            c = .off                       // 1초 엔진이 GPS를 쓰는 중 → 그 점을 받아 씀
        } else if q {
            c = p.keepAlive ? .keepAlive : .off
        } else {
            c = policy.config
        }
        // 발열 serious 이상: 이동 중 최고 정확도만 한 단계 낮춤 (자리 확인용 GPS는 그대로)
        if hot && policy.phase == .moving && c.acc == .best { c.acc = .ten }
        phase = policy.phase
        activity = policy.activity
        recorder?.activityHint = policy.activity

        // 앱이 꺼졌을 때 다시 깨우는 것들
        if p.regionWake {
            if !slcOn {
                manager.startMonitoringSignificantLocationChanges()
                manager.startMonitoringVisits()
                slcOn = true
            }
            if policy.phase != .moving, let ctr = policy.stayCenter { setRegion(ctr, radius: p.geofenceRadius) } else { removeRegion() }
        } else {
            if slcOn { manager.stopMonitoringSignificantLocationChanges(); manager.stopMonitoringVisits(); slcOn = false }
            removeRegion()
        }

        let key = (c, policy.activity, p.showIndicator)
        if let l = lastApplied, l.0 == key.0, l.1 == key.1, l.2 == key.2 { return }
        lastApplied = key
        config = c
        accumulateGPS(on: c.gpsOn)

        manager.showsBackgroundLocationIndicator = p.showIndicator
        if c.acc == .off {
            manager.stopUpdatingLocation()
            return
        }
        manager.allowsBackgroundLocationUpdates = true
        if a == .authorizedWhenInUse, bgSession == nil { bgSession = CLBackgroundActivitySession() }
        if a == .authorizedAlways { bgSession?.invalidate(); bgSession = nil }
        switch c.acc {
        case .off: break
        case .coarse: manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        case .hundred: manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        case .ten: manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        case .best: manager.desiredAccuracy = kCLLocationAccuracyBest
        }
        manager.distanceFilter = c.distance > 0 ? c.distance : kCLDistanceFilterNone
        switch policy.activity {
        case .car: manager.activityType = .automotiveNavigation
        case .walk, .run, .bike: manager.activityType = .fitness
        default: manager.activityType = .other
        }
        manager.startUpdatingLocation()
    }

    private func setRegion(_ c: (lat: Double, lon: Double), radius: Double) {
        let coord = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
        if let r = regionCenter, abs(r.latitude - coord.latitude) < 1e-6, abs(r.longitude - coord.longitude) < 1e-6 { return }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let reg = CLCircularRegion(center: coord, radius: min(radius, manager.maximumRegionMonitoringDistance),
                                   identifier: Self.regionId)
        reg.notifyOnEntry = false
        reg.notifyOnExit = true
        manager.startMonitoring(for: reg)
        regionCenter = coord
    }

    private func removeRegion() {
        for r in manager.monitoredRegions where r.identifier == Self.regionId { manager.stopMonitoring(for: r) }
        regionCenter = nil
    }

    // MARK: 타이머 (앱이 깨어 있는 동안만 돎 — 저정확도 위치가 깨워 둠)

    private func scheduleTick() {
        tickTimer?.invalidate(); tickTimer = nil
        guard running, !recorderOn, let at = policy.nextTick(now: now()) else { return }
        let t = Timer(fire: Date(timeIntervalSince1970: at), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(self.policy.tick(self.now()))
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func scheduleQuietTimer() {
        quietTimer?.invalidate(); quietTimer = nil
        let p = settings.prefs
        guard running, p.quietOn else { return }
        // 다음 정각에 다시 확인 (쉬는 시간 시작·끝이 시 단위)
        let cal = Calendar.current
        guard let next = cal.nextDate(after: Date(), matching: DateComponents(minute: 0, second: 0),
                                      matchingPolicy: .nextTime) else { return }
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastApplied = nil; self?.apply() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        quietTimer = t
    }

    // MARK: 입력 처리

    private func handle(_ evs: [DayEvent]) {
        let p = settings.prefs
        let q = p.isQuiet(Date())
        for e in evs {
            switch e {
            case .point(let pt):
                if q || p.isExcluded(lat: pt.lat, lon: pt.lon) { continue }
                store.append(pt)
            case .arrived(let v):
                if q || p.isExcluded(lat: v.lat, lon: v.lon) { continue }
                store.arrived(v)
            case .departed(let v):
                if p.isExcluded(lat: v.lat, lon: v.lon) { continue }
                store.departed(v)
            }
        }
        persist()
        apply()
        scheduleTick()
        evaluateDrive()
        Task { await upload(force: false) }
    }

    // MARK: CarPlay · 운전 1초 기록

    private func carPlayChanged(_ on: Bool) {
        if settings.prefs.carplaySend {
            let l = recorder?.lastGood ?? manager.location
            CarPlayEvents.shared.add(on, at: Date(), lat: l?.coordinate.latitude, lng: l?.coordinate.longitude)
        }
        if on {
            gate.carPlayConnected()
            Parking.shared.carReconnected(at: Date())
        } else if running {
            Parking.shared.parked(at: Date(), location: recorder?.lastGood ?? manager.location)
        }
        evaluateDrive()
    }

    /// 자동 운전 1초 기록 (경로 기록과 상관없음 — 점은 하루 기록에만). 규칙은 DriveGate.
    private func evaluateDrive() {
        guard let rec = recorder else { return }
        let p = settings.prefs
        let cp = CarPlayWatcher.shared
        let before = gate
        let a = gate.evaluate(.init(now: now(), enabled: p.enabled && p.driveRecord, carPlay: cp.connected,
                                    carPlaySince: cp.since?.timeIntervalSince1970, charging: charging,
                                    activity: policy.activity))
        switch a {
        case .start: rec.startAuto()
        case .stop: rec.stopAuto()
        case .none: break
        }
        if gate.driving && !rec.autoActive { rec.startAuto() }
        if !gate.driving && rec.autoActive { rec.stopAuto() }
        if gate.stopAt != before.stopAt { scheduleDriveTimer() }
        if gate != before {
            publishGate()
            if let d = try? JSONEncoder().encode(gate) { UserDefaults.standard.set(d, forKey: Self.gateKey) }
        }
    }

    private func publishGate() {
        if autoDriving != gate.driving { autoDriving = gate.driving }
        if driveLock != gate.lock { driveLock = gate.lock }
    }

    /// 유예가 끝나는 때 한 번 더 판단 (그 사이 위치가 안 와도)
    private func scheduleDriveTimer() {
        autoTimer?.invalidate(); autoTimer = nil
        guard let at = gate.stopAt else { return }
        let t = Timer(fire: Date(timeIntervalSince1970: at + 1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateDrive() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        autoTimer = t
    }

    /// 수동/자동 기록의 센서 추정점(터널) → 하루 기록에도 (같은 시각이면 서버에서 덮어씀)
    private func ingestEstimate(_ t: TrackPoint) {
        guard running else { return }
        let p = settings.prefs
        if p.isQuiet(Date()) || p.isExcluded(lat: t.lat, lon: t.lon) { return }
        store.append(DayPoint(ts: t.ts, lat: t.lat, lon: t.lon, alt: t.alt, acc: t.acc, spd: t.spd, src: "imu",
                              act: autoDriving ? "car" : policy.activity.rawValue))
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(policy.s) { UserDefaults.standard.set(d, forKey: Self.stateKey) }
    }

    private func onActivity(_ a: CMMotionActivity) {
        var k: DayActivity = .unknown
        if a.automotive { k = .car } else if a.cycling { k = .bike } else if a.running { k = .run }
        else if a.walking { k = .walk } else if a.stationary { k = .stationary }
        // 낮은 확신의 '움직임'은 무시 (주머니 속 흔들림)
        if k.moving && a.confidence == .low { return }
        if k == .unknown || k == policy.activity { return }
        handle(policy.motion(k, start: a.startDate.timeIntervalSince1970, now: now()))
    }

    private func fix(_ l: CLLocation, src: String) -> DayFix {
        DayFix(t: l.timestamp.timeIntervalSince1970, lat: l.coordinate.latitude, lon: l.coordinate.longitude,
               acc: l.horizontalAccuracy, spd: l.speed >= 0 ? l.speed : nil,
               alt: l.verticalAccuracy >= 0 ? l.altitude : nil, src: src)
    }

    private func ingestRecorderFix(_ l: CLLocation) {
        guard running else { return }
        Parking.shared.noteFix(l)
        handle(policy.fix(fix(l, src: "trk")))
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard self.running, !self.recorderOn else { return }
            for l in locations {
                guard l.horizontalAccuracy >= 0, l.timestamp.timeIntervalSinceNow > -120 else { continue }
                self.lastFixAt = l.timestamp
                Parking.shared.noteFix(l)
                if l.horizontalAccuracy > self.policy.opt.maxAcc {
                    // 정확도 낮은 위치(기지국 변화 등)가 머무는 곳에서 멀리 나옴 → GPS로 확인
                    if let c = self.policy.stayCenter,
                       DayGeo.dist(c.lat, c.lon, l.coordinate.latitude, l.coordinate.longitude) > l.horizontalAccuracy + self.policy.opt.stayRadius {
                        self.handle(self.policy.nudge(self.now()))
                    }
                    continue
                }
                self.handle(self.policy.fix(self.fix(l, src: "gps")))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        MainActor.assumeIsolated {
            if region.identifier.hasPrefix(AutoCheckin.prefix) {
                AutoCheckin.shared.regionEvent(region.identifier, enter: true, location: manager.location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        MainActor.assumeIsolated {
            if region.identifier.hasPrefix(AutoCheckin.prefix) {
                AutoCheckin.shared.regionEvent(region.identifier, enter: false, location: manager.location)
                return
            }
            guard self.running, region.identifier == Self.regionId else { return }
            self.handle(self.policy.nudge(self.now()))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        MainActor.assumeIsolated {
            guard self.running, visit.horizontalAccuracy >= 0 else { return }
            // 방문 감지는 늦게 옴 → 판단은 GPS 확인으로. 떠났다는 알림이면 바로 확인
            if visit.departureDate != .distantFuture {
                self.handle(self.policy.nudge(self.now()))
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            self.authorization = manager.authorizationStatus
            guard self.running else { return }
            if self.authorization == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
            self.lastApplied = nil
            self.apply()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        MainActor.assumeIsolated {
            if region?.identifier == Self.regionId { self.regionCenter = nil }
        }
    }

    // MARK: 업로드·통계

    func upload(force: Bool) async {
        let p = settings.prefs
        guard force || Date().timeIntervalSince(lastUploadTry) >= Double(p.uploadMinutes) * 60 else { return }
        lastUploadTry = Date()
        await store.upload(wifiOnly: p.wifiOnly)
        await MotionHistory.shared.upload(wifiOnly: p.wifiOnly)
        await CarPlayEvents.shared.flush()
        await AutoCheckin.shared.flush()
        await AutoCheckin.shared.refreshPlaces()
        await Baro.shared.upload(wifiOnly: p.wifiOnly)
        await WifiLog.shared.upload(wifiOnly: p.wifiOnly)
        await HealthHistory.shared.upload(wifiOnly: p.wifiOnly)
        await Parking.shared.flush()
        await FloorFixes.shared.flush()
    }

    private var gpsDay = ""

    private func loadGPSStat() {
        gpsDay = DayLogStore.dayKey(now() * 1000)
        gpsSecondsToday = UserDefaults.standard.double(forKey: "day.gps.\(gpsDay)")
    }

    /// GPS를 켠 시간 누적 (오늘)
    private func accumulateGPS(on: Bool) {
        let n = Date()
        if let s = gpsSince {
            let today = DayLogStore.dayKey(n.timeIntervalSince1970 * 1000)
            if today != gpsDay { gpsDay = today; gpsSecondsToday = 0 }
            gpsSecondsToday += n.timeIntervalSince(s)
            UserDefaults.standard.set(gpsSecondsToday, forKey: "day.gps.\(gpsDay)")
        }
        gpsSince = on ? n : nil
    }

    /// 화면에 보일 상태
    var statusText: String {
        if !running { return "꺼짐" }
        switch authorization {
        case .denied, .restricted: return "위치 권한이 꺼져 있음"
        case .notDetermined: return "권한 확인 중"
        default: break
        }
        let heat = hot ? " · 발열 심각, 정밀도 낮춤" : ""
        if autoDriving {
            return (CarPlayWatcher.shared.connected ? "운전" : "차량 이동") + " — 1초 기록 중"
                + (driveLock ? " (운전 끝까지 고정)" : " (충전 중)") + heat
        }
        if recorderOn { return "경로 기록 중 — 그 위치를 함께 저장" + heat }
        if quiet { return "쉬는 시간 — 저장 안 함" }
        switch phase {
        case .stationary: return "머무는 중 — GPS 꺼 둠" + (lowBattery ? " (배터리 절약)" : "")
        case .checking: return "자리 확인 중 (GPS 잠깐)"
        case .probing: return "움직임 감지 — 출발했는지 확인 중"
        case .moving: return activity.label + " — GPS " + accLabel + (lowBattery ? " (배터리 절약)" : charging && settings.prefs.chargePrecise ? " (충전 중 정밀)" : "") + heat
        }
    }

    private var accLabel: String {
        switch config.acc {
        case .off: return "끔"
        case .coarse: return "낮음"
        case .hundred: return "약 100m"
        case .ten: return "약 10m"
        case .best: return "최고"
        }
    }

    /// 지금 위치를 기록 안 할 장소로
    func currentLocation() -> CLLocation? { manager.location }
}
