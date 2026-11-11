import Foundation
import HealthKit

/// 건강 앱(HealthKit)에서 걸음·오른 층수를 가져와 서버로 (1.6).
/// 아이폰 만보계(MotionHistory)는 폰이 움직일 때만 셈 → 폰을 두고 다닐 때는 워치 기록이 필요.
/// - 오른 층수(flightsClimbed): 워치·폰이 기압계로 세는 '계단으로 오른 층' (약 3m = 1층). 내린 층은 건강 앱에 없음
/// - 걸음(stepCount): 워치가 센 것만 올림 (폰 걸음은 이미 day_step)
/// 새로 들어온 기록만 가져오는 anchored query — 워치 기록은 몇 분 늦게 들어오고, 지워진 것도 알려 줌.
/// 잠금 중에는 건강 기록을 못 읽음 → 실패하면 다음 업로드(앱 열 때 등)에 다시.
@MainActor
final class HealthHistory: ObservableObject {
    static let shared = HealthHistory()

    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastCount = 0

    private let store = HKHealthStore()
    private var busy = false
    private static let backfill: TimeInterval = 2 * 86400

    struct Item: Codable, Sendable {
        let uuid: String
        let kind: String        // steps | flights
        let start: Double       // epoch ms
        let end: Double
        let value: Double
        let device: String      // watch | phone | other
    }

    struct Body: Encodable {
        let items: [Item]
        let deleted: [String]
    }

    static var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private var types: [HKQuantityType] { [HKQuantityType(.stepCount), HKQuantityType(.flightsClimbed)] }

    /// 권한 묻기 (앱이 앞에 있을 때). 읽기 권한은 허용 여부를 앱이 알 수 없음 → 묻기만
    func requestPermission() {
        guard Self.available else { return }
        store.requestAuthorization(toShare: [], read: Set(types)) { _, _ in }
    }

    func upload(wifiOnly: Bool) async {
        guard Self.available, !busy, !AppSettings.shared.token.isEmpty, DaySettings.shared.prefs.watchHealth else { return }
        busy = true
        defer { busy = false }
        do {
            var n = 0
            for t in types {
                n += try await sync(t, cellular: !wifiOnly)
            }
            lastCount = n
            lastUploadAt = Date()
            lastError = nil
        } catch {
            lastError = "건강 앱: " + error.localizedDescription
        }
    }

    private func anchorKey(_ t: HKQuantityType) -> String { "health.anchor.\(t.identifier)" }

    private func sync(_ t: HKQuantityType, cellular: Bool) async throws -> Int {
        let ud = UserDefaults.standard
        var anchor: HKQueryAnchor?
        if let d = ud.data(forKey: anchorKey(t)) {
            anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: d)
        }
        let isSteps = t == HKQuantityType(.stepCount)
        let unit = HKUnit.count()
        let pred = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-Self.backfill), end: nil)
        let (added, deleted, next) = try await query(t, anchor: anchor, predicate: anchor == nil ? pred : nil)
        var items: [Item] = []
        for s in added {
            guard let q = s as? HKQuantitySample else { continue }
            let dev = Self.device(q)
            if isSteps && dev != "watch" { continue }       // 폰 걸음은 day_step 에 이미 있음
            items.append(Item(uuid: q.uuid.uuidString, kind: isSteps ? "steps" : "flights",
                              start: (q.startDate.timeIntervalSince1970 * 1000).rounded(),
                              end: (q.endDate.timeIntervalSince1970 * 1000).rounded(),
                              value: q.quantity.doubleValue(for: unit), device: dev))
        }
        let del = deleted.map { $0.uuid.uuidString }
        var i = 0
        repeat {
            let batch = Array(items[i..<min(items.count, i + 1000)])
            if !batch.isEmpty || (i == 0 && !del.isEmpty) {
                let _: OKResponse = try await API.send("POST", "day/health", body: Body(items: batch, deleted: i == 0 ? del : []),
                                                       cellular: cellular)
            }
            i += 1000
        } while i < items.count
        if let next, let d = try? NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true) {
            ud.set(d, forKey: anchorKey(t))
        }
        return items.count
    }

    nonisolated private static func device(_ s: HKSample) -> String {
        let p = s.sourceRevision.productType ?? ""
        let m = s.device?.model ?? ""
        if p.hasPrefix("Watch") || m.contains("Watch") { return "watch" }
        if p.hasPrefix("iPhone") || m.contains("iPhone") { return "phone" }
        return "other"
    }

    private nonisolated func query(_ t: HKQuantityType, anchor: HKQueryAnchor?, predicate: NSPredicate?) async throws
        -> ([HKSample], [HKDeletedObject], HKQueryAnchor?) {
        let st = store
        return try await withCheckedThrowingContinuation { cont in
            let q = HKAnchoredObjectQuery(type: t, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit) { _, added, deleted, next, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (added ?? [], deleted ?? [], next))
            }
            st.execute(q)
        }
    }
}
