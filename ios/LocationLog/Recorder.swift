import Foundation
import CoreLocation
import CoreMotion
import UIKit

/// GPS 기록. 웹판 app.js·track.js와 같은 규칙.
/// GPS가 끊기면(터널 등) 자이로·가속도·나침반으로 경로를 추정해 이어 붙이고(src='imu'), 다시 잡히면 보정.
/// - 앱이 앞에 있으면 기록 중이 아니어도 위치·방향을 받음(지도·속도·방향 표시용)
/// - 기록 중이면 화면이 꺼져도(백그라운드) 계속 받음
@MainActor
final class Recorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastLocation: CLLocation?   // 받은 마지막 위치(정확도 상관없이)
    @Published private(set) var lastGood: CLLocation?       // 정확도 통과한 마지막 위치
    @Published private(set) var weak = false                // 마지막 위치가 정확도 기준 밖
    @Published private(set) var compassHeading: Double?
    @Published private(set) var gpsError: String?
    @Published private(set) var estimating = false          // 센서로 이어 그리는 중
    @Published private(set) var lastCorrection: DeadReckoner.Correction?
    @Published var mode: TravelMode = .car {
        didSet {
            manager.activityType = mode.activityType
            if isRecording { store.setMode(mode) }
        }
    }

    static let maxAccuracy: Double = 40     // m — 이보다 나쁘면 버림
    static let maxSpeed: Double = 70        // m/s — 이보다 빠르면 튀는 값으로 봄
    static let longGap: Double = 120        // s — 이만큼 끊겼으면 순간 이동도 받아들임
    static let lossSec: Double = 3          // s — 움직이다 이만큼 못 받으면 'GPS 신호 약함'
    static let moveSpeed: Double = 2.5      // m/s
    static let minStep: Double = 5          // m — 직전 저장점에서 이만큼 안 움직였으면 저장 안 함(정차 중 중복)

    let store: TrackStore
    private let manager = CLLocationManager()
    private var bgSession: CLBackgroundActivitySession?
    private var lastAccepted: TrackPoint?
    private var jumpCandidate: CLLocation?
    private var lastSyncKick = Date.distantPast
    private var inForeground = true
    private let motion = CMMotionManager()
    private let reckoner = DeadReckoner()
    private var drSeqs: [Int] = []          // 이번 끊김에서 만든 추정점 seq (만든 순서)
    private var motionFrame: CMAttitudeReferenceFrame?
    private var transposeR: Bool?           // 회전 행렬 방향(기기마다 확인)

    init(store: TrackStore) {
        self.store = store
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // 거리 필터를 두면 멈춰 있을 때 위치가 아예 안 와서 'GPS 끊김'으로 오인함 → 1초마다 받고 저장할 때 거름
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 2
        manager.pausesLocationUpdatesAutomatically = false
        if let a = store.active {
            // 앱이 꺼졌다 다시 켜짐 → 이어서 기록
            mode = a.mode
            manager.activityType = a.mode.activityType
            lastAccepted = a.points.last
            beginRecording()
        } else {
            manager.activityType = mode.activityType
        }
        startUpdates()
    }

    // MARK: 화면에 보일 값

    var elapsed: TimeInterval {
        guard let t = store.active else { return 0 }
        return Date().timeIntervalSince1970 - t.startedAt / 1000
    }

    /// 최근 5초 안의 속도(m/s)
    var speed: Double? {
        if estimating { return reckoner.speed }
        guard let l = lastGood, Date().timeIntervalSince(l.timestamp) < 5, l.speed >= 0 else { return nil }
        return l.speed
    }

    /// 움직이면 GPS 진행 방향, 멈춰 있으면 나침반
    var heading: Double? {
        if estimating { return reckoner.course }
        if let s = speed, s > 1.5, let c = lastGood?.course, c >= 0 { return c }
        return compassHeading
    }

    enum StatusKind { case ok, warn, plain }

    func status() -> (text: String, kind: StatusKind) {
        if let e = gpsError { return (e, .warn) }
        if estimating, let l = lastGood {
            return ("GPS 끊김 · 센서로 이어 그리는 중 \(Int(Date().timeIntervalSince(l.timestamp)))초", .warn)
        }
        guard let l = lastGood else {
            return weak ? ("GPS 신호 약함", .warn) : ("위치 확인 중…", .plain)
        }
        let age = Date().timeIntervalSince(l.timestamp)
        if weak || (age > Self.lossSec && max(l.speed, 0) >= Self.moveSpeed) {
            return ("GPS 신호 약함", .warn)
        }
        return ("GPS ±\(Int(l.horizontalAccuracy.rounded()))m", .ok)
    }

    // MARK: 권한·켜고 끄기

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: if isRecording { manager.requestAlwaysAuthorization() }
        default: break
        }
    }

    /// 앱이 앞/뒤로 갈 때
    func setForeground(_ on: Bool) {
        inForeground = on
        if on { startUpdates() } else if !isRecording { stopUpdates() }
        applyIdleTimer()
    }

    private func startUpdates() {
        let a = manager.authorizationStatus
        guard a == .authorizedAlways || a == .authorizedWhenInUse else {
            if a == .notDetermined { manager.requestWhenInUseAuthorization() }
            return
        }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    private func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func applyIdleTimer() {
        // 웹판처럼 기록 중에는 화면 꺼짐 방지 (설정에서 끌 수 있음)
        let keep = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true
        UIApplication.shared.isIdleTimerDisabled = isRecording && inForeground && keep
    }

    func start() {
        guard !isRecording else { return }
        store.start(mode: mode)
        lastAccepted = nil
        jumpCandidate = nil
        beginRecording()
        // 방금 받은 GPS가 있으면 첫 점으로 사용
        if let l = lastGood, Date().timeIntervalSince(l.timestamp) < 3 { handle(l) }
        Task { await store.sync() }
    }

    /// 끝낸 기록 이름 반환
    @discardableResult
    func stop() -> String? {
        guard isRecording else { return nil }
        let name = store.active?.name
        manager.allowsBackgroundLocationUpdates = false
        bgSession?.invalidate()
        bgSession = nil
        stopMotion()
        isRecording = false
        if !inForeground { stopUpdates() }
        applyIdleTimer()
        store.finish()
        Task { await store.sync() }
        return name
    }

    private func beginRecording() {
        isRecording = true
        requestPermission()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        bgSession = CLBackgroundActivitySession()
        startUpdates()
        startMotion()
        applyIdleTimer()
    }

    // MARK: CLLocationManagerDelegate (메인 스레드에서 만든 manager → 메인 스레드로 옴)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for l in locations { self.handle(l) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated {
            guard newHeading.headingAccuracy >= 0 else { return }
            self.compassHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
            self.reckoner.compass(newHeading.headingAccuracy <= 30 ? self.compassHeading : nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            self.authorization = manager.authorizationStatus
            switch self.authorization {
            case .denied, .restricted:
                self.gpsError = "위치 권한이 꺼져 있습니다 (설정 › 개인정보 보호 › 위치 서비스 › Sillage)"
            case .authorizedWhenInUse, .authorizedAlways:
                self.gpsError = nil
                if self.inForeground || self.isRecording { self.startUpdates() }
                if self.authorization == .authorizedWhenInUse && self.isRecording {
                    manager.requestAlwaysAuthorization()
                }
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            guard let e = error as? CLError else { return }
            if e.code == .locationUnknown { return }
            if e.code == .denied {
                self.gpsError = "위치 권한이 꺼져 있습니다 (설정 › 개인정보 보호 › 위치 서비스 › Sillage)"
            } else {
                self.gpsError = "위치를 못 받고 있습니다"
            }
        }
    }

    // MARK: 점 거르기

    private func handle(_ loc: CLLocation) {
        guard loc.horizontalAccuracy >= 0 else { return }
        guard loc.timestamp.timeIntervalSinceNow > -30 else { return }     // 오래된 캐시 위치
        lastLocation = loc
        gpsError = nil
        guard loc.horizontalAccuracy <= Self.maxAccuracy else {
            weak = true
            return
        }
        weak = false
        lastGood = loc
        guard isRecording else { return }

        let ts = loc.timestamp.timeIntervalSince1970 * 1000
        var brk = false
        var add = 0.0
        let wasDR = reckoner.isEstimating
        let corr = reckoner.gps(.init(t: loc.timestamp.timeIntervalSince1970,
                                      lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                                      alt: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
                                      acc: loc.horizontalAccuracy,
                                      spd: loc.speed >= 0 ? loc.speed : nil,
                                      hdg: loc.course >= 0 ? loc.course : nil))
        if wasDR { finishEstimate(corr) }
        if wasDR, let last = lastAccepted {
            // 추정 끝점 → 복귀 위치: 순간 이동 검사 없이 이어 붙임(보정으로 맞춰짐)
            if (ts - last.ts) <= 0 { return }
            add = loc.distance(from: last.location)
        } else if let last = lastAccepted {
            let dt = (ts - last.ts) / 1000
            if dt <= 0 { return }
            let d = loc.distance(from: last.location)
            if d / dt > Self.maxSpeed {
                // 순간 이동(비행 등): 오래 끊겼거나 연속 두 번 같은 곳이면 받아들이고 선은 끊음
                if dt >= Self.longGap {
                    brk = true
                } else if let c = jumpCandidate, loc.distance(from: c) < max(50, loc.horizontalAccuracy * 2) {
                    brk = true
                } else {
                    jumpCandidate = loc
                    return
                }
            } else if d < Self.minStep {
                // 정차 중: 위치는 받았으니(끊김 아님) 추정기에는 알렸고, 같은 자리 점은 저장 안 함
                jumpCandidate = nil
                return
            } else {
                add = d
            }
        }
        jumpCandidate = nil
        let p = TrackPoint(seq: store.active?.nextSeq ?? 0, ts: ts,
                           lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                           alt: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
                           acc: loc.horizontalAccuracy,
                           spd: loc.speed >= 0 ? loc.speed : nil,
                           hdg: loc.course >= 0 ? loc.course : nil,
                           src: "gps", brk: brk ? true : nil)
        store.append(p, distanceAdd: add)
        lastAccepted = p
        // 백그라운드에서는 타이머가 안 도니 위치 받을 때 15초마다 올림
        if Date().timeIntervalSince(lastSyncKick) > 15 {
            lastSyncKick = Date()
            Task { await store.sync() }
        }
    }
}

// MARK: 센서 추정 (GPS 끊김 구간)

extension Recorder {
    fileprivate func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        // 진북 기준이면 가속도를 동·북으로 나눌 수 있음. 없으면 회전만 쓰고 속도는 직전 GPS 값으로
        let f: CMAttitudeReferenceFrame = frames.contains(.xTrueNorthZVertical) ? .xTrueNorthZVertical : .xArbitraryZVertical
        motionFrame = f
        reckoner.reset()
        drSeqs = []
        motion.deviceMotionUpdateInterval = 1.0 / 25
        motion.startDeviceMotionUpdates(using: f, to: .main) { [weak self] dm, _ in
            guard let self, let dm else { return }
            MainActor.assumeIsolated { self.onMotion(dm) }
        }
    }

    fileprivate func stopMotion() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
        if reckoner.isEstimating { finishEstimate(nil) }
        reckoner.reset()
        estimating = false
    }

    private func onMotion(_ dm: CMDeviceMotion) {
        guard isRecording else { return }
        let g = dm.gravity, w = dm.rotationRate, a = dm.userAcceleration
        let gn = max(1e-6, (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot())
        // 수직축 회전(위에서 볼 때 시계 방향 +): ω·ĝ (ĝ = 아래 방향)
        let yawRateCW = (w.x * g.x + w.y * g.y + w.z * g.z) / gn * 180 / .pi
        var aN: Double?, aE: Double?
        if motionFrame == .xTrueNorthZVertical {
            let r = dm.attitude.rotationMatrix
            // 회전 행렬이 기기→기준인지 기준→기기인지: 중력이 기준 좌표에서 (0,0,-1)이 되는 쪽
            if transposeR == nil {
                let z1 = r.m31 * g.x + r.m32 * g.y + r.m33 * g.z   // R·g
                let z2 = r.m13 * g.x + r.m23 * g.y + r.m33 * g.z   // Rᵀ·g
                if abs(z1 - z2) > 0.5 { transposeR = abs(z2 + gn) < abs(z1 + gn) }
            }
            if let tr = transposeR {
                let G = 9.80665
                let x = tr ? r.m11 * a.x + r.m21 * a.y + r.m31 * a.z : r.m11 * a.x + r.m12 * a.y + r.m13 * a.z
                let y = tr ? r.m12 * a.x + r.m22 * a.y + r.m32 * a.z : r.m21 * a.x + r.m22 * a.y + r.m23 * a.z
                aN = x * G          // x = 진북
                aE = -y * G         // y = 서쪽
            }
        }
        let t = Date().timeIntervalSince1970   // dm.timestamp는 부팅 기준 → GPS와 같은 시계로
        let pts = reckoner.motion(t: t, yawRateCW: yawRateCW, aNorth: aN, aEast: aE)
        if estimating && !reckoner.isEstimating {
            // GPS 없이 추정이 멈춤(앱 멈춤·너무 긴 끊김) → 보정 없이 남김
            estimating = false
            drSeqs = []
        } else if !estimating && reckoner.isEstimating { estimating = true }
        for q in pts { appendEstimate(q) }
    }

    private func appendEstimate(_ q: DeadReckoner.Point) {
        guard let seq = store.active?.nextSeq else { return }
        let p = TrackPoint(seq: seq, ts: q.t * 1000, lat: q.lat, lon: q.lon, alt: q.alt, acc: q.acc,
                           spd: q.spd, hdg: q.hdg, src: "imu", brk: nil)
        let add = lastAccepted.map { p.location.distance(from: $0.location) } ?? 0
        store.append(p, distanceAdd: add)
        lastAccepted = p
        drSeqs.append(seq)
    }

    /// GPS 복귀: 추정점을 보정된 좌표로 바꿔 다시 올림
    fileprivate func finishEstimate(_ c: DeadReckoner.Correction?) {
        estimating = false
        defer { drSeqs = [] }
        guard let c, !drSeqs.isEmpty else { return }
        let fixed = zip(drSeqs, c.points).map { seq, q in
            TrackPoint(seq: seq, ts: q.t * 1000, lat: q.lat, lon: q.lon, alt: q.alt, acc: q.acc,
                       spd: q.spd, hdg: q.hdg, src: "imu", brk: nil)
        }
        store.correct(fixed)
        if let l = fixed.last { lastAccepted = l }
        lastCorrection = c
    }
}
