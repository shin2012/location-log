import Foundation
import CoreLocation
import UIKit

/// GPS 기록. 백그라운드(화면 꺼짐·다른 앱)에서도 계속 받음.
/// 웹판 track.js의 거름 규칙(정확도 40m, 70m/s 넘는 순간 이동 처리)을 따름.
/// TODO(Mac): 터널 구간 추정(CoreMotion 가속도·자이로·나침반) — 웹판 DR 이식
@MainActor
final class Recorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var status = "대기"
    @Published var mode: TravelMode = .car {
        didSet {
            manager.activityType = mode.activityType
            if isRecording { store.setMode(mode) }
        }
    }

    static let maxAccuracy: Double = 40     // m — 이보다 나쁘면 버림
    static let maxSpeed: Double = 70        // m/s — 이보다 빠르면 튀는 값으로 봄
    static let longGap: Double = 120        // s — 이만큼 끊겼으면 순간 이동도 받아들임

    let store: TrackStore
    private let manager = CLLocationManager()
    private var bgSession: CLBackgroundActivitySession?
    private var lastAccepted: TrackPoint?
    private var jumpCandidate: CLLocation?
    private var lastSyncKick = Date.distantPast

    init(store: TrackStore) {
        self.store = store
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        if let a = store.active {
            // 앱이 꺼졌다 다시 켜짐 → 이어서 기록
            mode = a.mode
            manager.activityType = a.mode.activityType
            lastAccepted = a.points.last
            beginUpdates()
        } else {
            manager.activityType = mode.activityType
        }
    }

    var elapsed: TimeInterval {
        guard let t = store.active else { return 0 }
        return Date().timeIntervalSince1970 - t.startedAt / 1000
    }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    func start() {
        guard !isRecording else { return }
        store.start(mode: mode)
        lastAccepted = nil
        jumpCandidate = nil
        beginUpdates()
    }

    func stop() {
        guard isRecording else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        bgSession?.invalidate()
        bgSession = nil
        isRecording = false
        status = "대기"
        UIApplication.shared.isIdleTimerDisabled = false
        store.finish()
        Task { await store.sync() }
    }

    private func beginUpdates() {
        requestPermission()
        isRecording = true
        status = "GPS 찾는 중"
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        bgSession = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate (메인 스레드에서 만든 manager → 메인 스레드로 옴)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for l in locations { self.handle(l) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            self.authorization = manager.authorizationStatus
            if self.authorization == .authorizedWhenInUse && self.isRecording {
                manager.requestAlwaysAuthorization()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if (error as? CLError)?.code == .locationUnknown { return }
            self.status = "위치 오류: \(error.localizedDescription)"
        }
    }

    // MARK: 점 거르기

    private func handle(_ loc: CLLocation) {
        lastLocation = loc
        guard isRecording else { return }
        guard loc.horizontalAccuracy >= 0 else { return }
        guard loc.timestamp.timeIntervalSinceNow > -30 else { return }     // 오래된 캐시 위치
        guard loc.horizontalAccuracy <= Self.maxAccuracy else {
            status = "GPS 약함 (±\(Int(loc.horizontalAccuracy))m)"
            return
        }
        let ts = loc.timestamp.timeIntervalSince1970 * 1000
        var brk = false
        var add = 0.0
        if let last = lastAccepted {
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
                    status = "튀는 값 무시"
                    return
                }
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
        status = "GPS ±\(Int(loc.horizontalAccuracy))m"
        // 백그라운드에서는 타이머가 안 도니 위치 받을 때 15초마다 올림
        if Date().timeIntervalSince(lastSyncKick) > 15 {
            lastSyncKick = Date()
            Task { await store.sync() }
        }
    }
}
