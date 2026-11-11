import Foundation
import CoreLocation
import UserNotifications

/// 주차 층: CarPlay 해제 순간 기압을 '마지막으로 빠르게 달린 곳(지상 도로)' 기압과 비교 → 층 추정 → 1분 뒤 알림 + 서버 기록.
/// 1분 안에 CarPlay 가 다시 붙으면(잠깐 끊김) 알림·기록 모두 취소.
/// 알림 버튼(맞아요 / 한 층 위 / 한 층 아래)이나 타임라인에서 고치면 서버 park.level_user → 그 장소(150m) 보정에 쓰임.
@MainActor
final class Parking: ObservableObject {
    static let shared = Parking()

    struct Post: Codable, Equatable {
        let ts: Double          // epoch ms (CarPlay 해제)
        let lat: Double?
        let lon: Double?
        let dh: Double
        let refTs: Double?
        let level: Int
    }

    @Published private(set) var lastPark: Post?
    @Published private(set) var lastError: String?

    private var lastFast: Double?               // epoch s — 속도 5m/s 이상, 정확도 30m 안
    private var posts: [Post] = []
    private var patches: [String: Int] = [:]   // ts ms(문자열) → 층, -99 = 고친 것 취소
    private var cal: [ParkCal] = []
    private var calAt = Date.distantPast
    private var sending = false

    static let category = "park"
    static let notifId = "park.now"
    static let actOK = "park.ok", actUp = "park.up", actDown = "park.down"
    private static let postsKey = "park.posts", patchesKey = "park.patches", calKey = "park.cal", lastKey = "park.last"
    private static let delay: TimeInterval = 60
    private static let refMax: TimeInterval = 30 * 60

    private init() {
        let ud = UserDefaults.standard
        let dec = JSONDecoder()
        if let d = ud.data(forKey: Self.postsKey), let v = try? dec.decode([Post].self, from: d) { posts = v }
        if let d = ud.data(forKey: Self.calKey), let v = try? dec.decode([ParkCal].self, from: d) { cal = v }
        if let d = ud.data(forKey: Self.lastKey), let v = try? dec.decode(Post.self, from: d) { lastPark = v }
        patches = (ud.dictionary(forKey: Self.patchesKey) as? [String: Int]) ?? [:]
    }

    // MARK: 알림 준비 (App.init)

    static func registerCategory() {
        let ok = UNNotificationAction(identifier: actOK, title: "맞아요")
        let up = UNNotificationAction(identifier: actUp, title: "한 층 위")
        let down = UNNotificationAction(identifier: actDown, title: "한 층 아래")
        let c = UNNotificationCategory(identifier: category, actions: [ok, up, down], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([c])
    }

    func requestPermission() {
        let c = UNUserNotificationCenter.current()
        c.getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: 입력

    /// 위치마다 (하루 기록·1초 엔진 둘 다)
    func noteFix(_ l: CLLocation) {
        if l.speed >= 5, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 30 {
            lastFast = l.timestamp.timeIntervalSince1970
        }
    }

    /// CarPlay 해제
    func parked(at d: Date, location: CLLocation?) {
        let now = d.timeIntervalSince1970
        guard let f = lastFast, now - f <= Self.refMax, now - f >= 0,
              let pr = Baro.shared.pressure(at: f), let pn = Baro.shared.pressure(at: now) else { return }
        let dh = ParkModel.dh(refKpa: pr, nowKpa: pn)
        let lat = location?.coordinate.latitude, lon = location?.coordinate.longitude
        let level = lat.flatMap { la in lon.map { ParkModel.estimate(dh: dh, lat: la, lon: $0, cal: cal) } }
            ?? ParkModel.estimate(dh: dh, lat: 0, lon: 0, cal: [])
        let p = Post(ts: (now * 1000).rounded(), lat: lat, lon: lon, dh: (dh * 100).rounded() / 100,
                     refTs: (f * 1000).rounded(), level: level)
        posts.append(p)
        Archives.park.append([p]); Archives.park.markAllUploaded()   // 보관 (보내기는 posts 가 맡음)
        if posts.count > 50 { posts.removeFirst(posts.count - 50) }
        lastPark = p
        save()
        if DaySettings.shared.prefs.parkNotify { notify(p) }
    }

    /// CarPlay 다시 연결 — 방금 해제(2분 안)는 잠깐 끊김으로 보고 취소
    func carReconnected(at d: Date) {
        let ms = d.timeIntervalSince1970 * 1000
        let before = posts.count
        posts.removeAll { ms - $0.ts < 120_000 }
        if posts.count != before {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notifId])
            if let l = lastPark, ms - l.ts < 120_000 { lastPark = nil }
            save()
        }
    }

    private func notify(_ p: Post) {
        let c = UNMutableNotificationContent()
        c.title = "주차 \(ParkModel.label(p.level)) (추정)"
        c.body = "맞으면 그대로 두세요. 알림을 길게 눌러 한 층 위·아래로 고칠 수 있어요."
        c.categoryIdentifier = Self.category
        c.userInfo = ["ts": p.ts, "level": p.level]
        c.threadIdentifier = "park"
        let t = UNTimeIntervalNotificationTrigger(timeInterval: Self.delay, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notifId, content: c, trigger: t))
    }

    /// 알림 버튼
    func handleAction(_ id: String, ts: Double, level lv: Int) async {
        switch id {
        case Self.actOK: await setLevel(ts: ts, level: lv)
        case Self.actUp: await setLevel(ts: ts, level: lv + 1)
        case Self.actDown: await setLevel(ts: ts, level: lv - 1)
        default: break
        }
    }

    /// 사용자가 층을 정함 (nil = 고친 것 취소)
    func setLevel(ts: Double, level: Int?) async {
        patches[String(Int(ts.rounded()))] = level ?? -99
        Archives.edits.append([EditRecord(at: (Date().timeIntervalSince1970 * 1000).rounded(), kind: "park", ts: ts, level: level)])
        Archives.edits.markAllUploaded()
        if let level, let p = posts.first(where: { abs($0.ts - ts) < 2 }) ?? (lastPark.flatMap { abs($0.ts - ts) < 2 ? $0 : nil }),
           let la = p.lat, let lo = p.lon {
            cal.append(ParkCal(lat: la, lon: lo, dh: p.dh, level: level))   // 통신 전에도 다음 추정에 바로 반영
        }
        save()
        await flush(force: true)
    }

    /// 고친 층이 아직 서버에 안 갔음 (통신 안 됨)
    func isPending(_ ts: Double) -> Bool { patches[String(Int(ts.rounded()))] != nil }

    // MARK: 서버

    struct PatchBody: Encodable { let level: Int? }

    func flush(force: Bool = false) async {
        guard !sending, !AppSettings.shared.token.isEmpty else { return }
        sending = true
        defer { sending = false; save() }
        let now = Date().timeIntervalSince1970 * 1000
        do {
            // 해제 1분 지난 것만 (그 안에 다시 붙으면 취소되므로)
            while let p = posts.first(where: { now - $0.ts >= Self.delay * 1000 || force && patches[String(Int($0.ts.rounded()))] != nil }) {
                let _: OKResponse = try await API.send("POST", "park", body: p)
                posts.removeAll { $0 == p }
            }
            for (k, v) in patches {
                guard let ts = Int(k) else { patches[k] = nil; continue }
                // 아직 안 올린 주차면 다음에
                if posts.contains(where: { Int($0.ts.rounded()) == ts }) { continue }
                do {
                    let _: OKResponse = try await API.send("PATCH", "park/\(ts)", body: PatchBody(level: v == -99 ? nil : v))
                    patches[k] = nil
                } catch let e as APIError where e.message.contains("404") {
                    patches[k] = nil
                }
            }
            if Date().timeIntervalSince(calAt) > 6 * 3600 || force {
                cal = try await API.send("GET", "park/calib")
                calAt = Date()
            }
            lastError = nil
        } catch {
            lastError = "주차: " + error.localizedDescription
        }
    }

    private func save() {
        let ud = UserDefaults.standard
        let enc = JSONEncoder()
        ud.set(try? enc.encode(posts), forKey: Self.postsKey)
        ud.set(try? enc.encode(cal), forKey: Self.calKey)
        ud.set(lastPark.flatMap { try? enc.encode($0) }, forKey: Self.lastKey)
        ud.set(patches, forKey: Self.patchesKey)
    }
}

/// 알림 받는 쪽 (App.init 에서 delegate 로). 앱이 꺼져 있어도 버튼을 누르면 백그라운드로 켜져 여기로 옴.
final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        guard response.notification.request.content.categoryIdentifier == Parking.category,
              let ts = (info["ts"] as? NSNumber)?.doubleValue, let lv = (info["level"] as? NSNumber)?.intValue else { return }
        await Parking.shared.handleAction(id, ts: ts, level: lv)
    }
}
