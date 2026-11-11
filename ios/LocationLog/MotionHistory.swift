import Foundation
import CoreMotion

/// 이동 방식(기기 동작 기록)과 1분 걸음(만보계)을 서버로 올림.
///
/// iOS가 두 기록을 기기에 최근 7일만 보관하므로, 업로드 때마다 지난번 커서부터 조회해 앱 보관함(Archives)에 영구 저장하고 거기서 올린다.
/// 앱이 잠들어 실시간 감지를 못 받은 구간도 이렇게 채워진다. 권한은 '동작 및 피트니스' 하나.
/// - 이동 방식: 바뀐 시각만 (같은 방식 연속은 하나로). 확신 낮은 '움직임'은 버림 (주머니 속 흔들림)
/// - 걸음: 1분 단위, 0 걸음 분도 올림 (행이 있으면 그 분은 측정됨). 한 시간이 통째로 0이면 분별 조회 생략
@MainActor
final class MotionHistory: ObservableObject {
    static let shared = MotionHistory()

    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastError: String?

    private var busy = false

    private static let actCursorKey = "motion.actCursor"
    private static let actLastKey = "motion.actLast"
    private static let stepCursorKey = "motion.stepCursor"
    /// iOS 보관 7일보다 조금 짧게 (경계에서 빈 결과 방지)
    private static let keep: TimeInterval = 7 * 86400 - 900
    /// 처음 켤 때 걸음을 거슬러 올라갈 기간
    private static let stepBackfill: TimeInterval = 2 * 86400
    /// 한 번에 조회할 걸음 분 수 (백그라운드 시간 제한 대비, 남은 건 다음 업로드에)
    private static let stepMinutesPerRun = 24 * 60

    struct ActItem: Codable { let ts: Double; let act: String; let conf: Int }
    struct StepItem: Codable { let ts: Double; let steps: Int; let dist: Double?; var up: Int? = nil; var down: Int? = nil }
    struct ActsBody: Encodable { let acts: [ActItem] }
    struct StepsBody: Encodable { let steps: [StepItem] }

    /// 동작 기록 조회 결과 (Sendable 하게 옮기려고 값만 꺼냄)
    struct Act: Sendable { let start: Date; let kind: String; let conf: Int; let moving: Bool }

    /// iOS 기록 → 앱 보관함(Archives, 지우지 않음) → 서버. 보관은 통신·토큰과 상관없이 먼저
    func upload(wifiOnly: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await collectActs()
            try await collectSteps()
            guard !AppSettings.shared.token.isEmpty else { return }
            let cellular = !wifiOnly
            try await Archives.acts.upload { b in
                let _: OKResponse = try await API.send("POST", "day/acts", body: ActsBody(acts: b), cellular: cellular)
            }
            try await Archives.steps.upload(batch: 600) { b in
                let _: OKResponse = try await API.send("POST", "day/steps", body: StepsBody(steps: b), cellular: cellular)
            }
            lastUploadAt = Date()
            lastError = nil
        } catch {
            lastError = "동작·걸음: " + error.localizedDescription
        }
    }

    // MARK: 이동 방식

    nonisolated static func kind(_ a: CMMotionActivity) -> String {
        if a.automotive { return "car" }
        if a.cycling { return "bike" }
        if a.running { return "run" }
        if a.walking { return "walk" }
        if a.stationary { return "stationary" }
        return "unknown"
    }

    private func collectActs() async throws {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else { return }
        let ud = UserDefaults.standard
        let now = Date()
        let floor = now.addingTimeInterval(-Self.keep)
        let saved = ud.double(forKey: Self.actCursorKey)
        let from = max(saved > 0 ? Date(timeIntervalSince1970: saved) : floor, floor)
        guard from < now else { return }
        let list = try await queryActs(from, now)
        var last = ud.string(forKey: Self.actLastKey)
        var out: [ActItem] = []
        for a in list {
            if a.kind == "unknown" || (a.moving && a.conf == 0) { continue }
            if a.kind == last { continue }
            out.append(ActItem(ts: (a.start.timeIntervalSince1970 * 1000).rounded(), act: a.kind, conf: a.conf))
            last = a.kind
        }
        Archives.acts.append(out)
        // 마지막 항목은 아직 진행 중일 수 있지만 시작 시각은 고정 → 그 다음부터 다시 조회
        if let l = list.last { ud.set(l.start.timeIntervalSince1970 + 0.001, forKey: Self.actCursorKey) }
        if let last { ud.set(last, forKey: Self.actLastKey) }
    }

    nonisolated func queryActs(_ from: Date, _ to: Date) async throws -> [Act] {
        let mgr = CMMotionActivityManager()
        return try await withCheckedThrowingContinuation { cont in
            mgr.queryActivityStarting(from: from, to: to, to: OperationQueue()) { acts, err in
                _ = mgr   // 결과가 올 때까지 관리자를 붙잡아 둠
                if let err { cont.resume(throwing: err); return }
                let v = (acts ?? []).map {
                    Act(start: $0.startDate, kind: MotionHistory.kind($0), conf: $0.confidence.rawValue,
                        moving: $0.walking || $0.running || $0.cycling || $0.automotive)
                }
                cont.resume(returning: v)
            }
        }
    }

    // MARK: 걸음

    private func collectSteps() async throws {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let auth = CMPedometer.authorizationStatus()
        guard auth == .authorized || auth == .notDetermined else { return }
        let ud = UserDefaults.standard
        let now = Date()
        let end = Self.minuteFloor(now)   // 끝난 분까지만
        let floor = Self.minuteFloor(now.addingTimeInterval(-Self.keep))
        let saved = ud.double(forKey: Self.stepCursorKey)
        var t = saved > 0 ? Date(timeIntervalSince1970: saved) : Self.minuteFloor(now.addingTimeInterval(-Self.stepBackfill))
        if t < floor { t = floor }
        var buf: [StepItem] = []
        var minutes = 0
        func flush() async throws {
            guard !buf.isEmpty else { return }
            Archives.steps.append(buf)
            buf.removeAll()
            ud.set(t.timeIntervalSince1970, forKey: Self.stepCursorKey)
        }
        while t < end && minutes < Self.stepMinutesPerRun {
            let blockEnd = min(t.addingTimeInterval(3600), end)
            let total = try await querySteps(t, blockEnd)
            var m = t
            if total.steps == 0 {
                while m < blockEnd {
                    buf.append(StepItem(ts: m.timeIntervalSince1970 * 1000, steps: 0, dist: 0))
                    m = m.addingTimeInterval(60)
                }
            } else {
                while m < blockEnd {
                    let n = m.addingTimeInterval(60)
                    let r = try await querySteps(m, n)
                    buf.append(StepItem(ts: m.timeIntervalSince1970 * 1000, steps: r.steps, dist: r.dist, up: r.up, down: r.down))
                    m = n
                }
            }
            minutes += Int(blockEnd.timeIntervalSince(t) / 60)
            t = blockEnd
            if buf.count >= 600 { try await flush() }
        }
        try await flush()
    }

    /// up/down = 만보계가 센 계단 오르내린 층수 (기기가 지원할 때만)
    private nonisolated func querySteps(_ from: Date, _ to: Date) async throws -> (steps: Int, dist: Double?, up: Int?, down: Int?) {
        let ped = CMPedometer()
        return try await withCheckedThrowingContinuation { cont in
            ped.queryPedometerData(from: from, to: to) { data, err in
                _ = ped
                if let err = err as NSError? {
                    // 기록 없음(기기 꺼짐 등)은 0 으로
                    if err.domain == CMErrorDomain && err.code == Int(CMErrorNilData.rawValue) { cont.resume(returning: (0, nil, nil, nil)); return }
                    cont.resume(throwing: err); return
                }
                cont.resume(returning: (data?.numberOfSteps.intValue ?? 0, data?.distance?.doubleValue,
                                        data?.floorsAscended?.intValue, data?.floorsDescended?.intValue))
            }
        }
    }

    static func minuteFloor(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}
