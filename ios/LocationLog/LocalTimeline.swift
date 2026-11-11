import Foundation

/// 타임라인 = 기기에서 계산 (TimelineCalc). 오프라인이어도 기기 보관함만으로 바로 보이고,
/// 연결되면 서버 보완 정보(체크인 이름·장소·보정값·단축어 CarPlay·다른 기기 기록)를 받아 기기에 저장 → 다시 계산 → 결과를 서버에 보관.
/// 서버 보완 정보 저장 = Application Support/inputs/YYYY-MM-DD.json (지우지 않음, 다음 오프라인 때도 씀).
@MainActor
enum LocalTimeline {
    static let kst = TimeZone(identifier: "Asia/Seoul")!

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = kst
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 한국 날짜 [0시, 다음 0시) epoch ms — 서버 day_range 와 같게
    static func range(_ day: String) -> (Double, Double) {
        let d = fmt.date(from: day) ?? Date()
        let a = d.timeIntervalSince1970 * 1000
        return (a, a + 86_400_000)
    }

    /// 기기 보관 파일은 기기 시간대 날짜로 나뉨 → 앞뒤 하루까지 읽고 계산이 시간 창으로 거름
    static func near(_ day: String) -> [String] {
        let (a, _) = range(day)
        return [-1.0, 0, 1].map { DayLogStore.dayKey(a + 43_200_000 + $0 * 86_400_000) }
    }

    // MARK: 기기 원본

    static func localInputs(_ day: String) -> CalcInput {
        let (a, b) = range(day)
        let ds = near(day)
        let store = DayLogger.shared.store
        var inp = CalcInput(day0: a, day1: b, now: Date().timeIntervalSince1970 * 1000)
        inp.visits = store.meta.visits.filter { $0.arrive < b && ($0.depart == nil || $0.depart! > a - 43_200_000) }
            .map { .init(arrive: $0.arrive, depart: $0.depart, lat: $0.lat, lon: $0.lon) }
        let pdays = TimeZone.current.secondsFromGMT() == kst.secondsFromGMT() ? [DayLogStore.dayKey(a + 43_200_000)] : ds
        inp.points = pdays.flatMap { store.points($0, sorted: false) }.filter { $0.ts >= a && $0.ts < b }
            .map { .init(ts: $0.ts, lat: $0.lat, lon: $0.lon, src: $0.src, act: $0.act) }
        inp.acts = ds.flatMap { Archives.acts.items($0) }.map { .init(ts: $0.ts, act: $0.act) }
        inp.steps = ds.flatMap { Archives.steps.items($0) }.map { .init(ts: $0.ts, steps: $0.steps, up: $0.up, down: $0.down) }
        inp.baro = ds.flatMap { Baro.shared.samples($0) }.map { .init(ts: $0.ts, kpa: $0.kpa) }
        inp.wifi = ds.flatMap { Archives.wifi.items($0) }.map { .init(ts: $0.ts, bssid: $0.bssid) }
        inp.hk = ds.flatMap { Archives.health.items($0) }.filter { $0.kind != HealthHistory.deletedKind }
            .map { .init(uuid: $0.uuid, kind: $0.kind, start: $0.start, end: $0.end, value: $0.value, device: $0.device) }
        inp.car = ds.flatMap { Archives.carplay.items($0) }.map { .init(ts: $0.ts, event: $0.event) }
        inp.parks = ds.flatMap { Archives.park.items($0) }
            .map { .init(ts: $0.ts, lat: $0.lat, lon: $0.lon, dh: $0.dh, levelEst: $0.level, levelUser: nil) }
        inp.places = AutoCheckin.shared.places.map { .init(name: $0.name, lat: $0.lat, lon: $0.lon, radius: $0.radius) }
        inp.parkCal = Parking.shared.calibration
        return inp
    }

    // MARK: 서버 보완 (저장본)

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// (서버 재료, 받은 시각)
    static func serverCache(_ day: String) -> (CalcInput, Date)? {
        let u = dir.appendingPathComponent("\(day).json")
        guard let d = try? Data(contentsOf: u), let v = try? API.decode(CalcInput.self, d) else { return nil }
        let at = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? Date()
        return (v, at)
    }

    /// 서버에서 보완 정보 받아 저장. 기기에 이미 있는 큰 원본(위치 점·기압)은 빼고 받음
    static func refresh(_ day: String) async throws {
        let loc = localInputs(day)
        var have: [String] = []
        if !loc.points.isEmpty { have.append("points") }
        if !loc.baro.isEmpty { have.append("baro") }
        let q = have.isEmpty ? "" : "?have=" + have.joined(separator: ",")
        let data = try await API.raw("GET", "day/\(day)/inputs" + q, timeout: 15)
        _ = try API.decode(CalcInput.self, data)          // 깨진 응답은 저장 안 함
        try? data.write(to: dir.appendingPathComponent("\(day).json"), options: .atomic)
    }

    // MARK: 합치기 (기기 우선, 사용자 고침은 마지막에)

    static func merged(_ day: String) -> CalcInput {
        var m = localInputs(day)
        guard let (s, _) = serverCache(day) else { return applyEdits(m) }
        func union<T>(_ server: [T], _ local: [T], key: (T) -> String) -> [T] {
            var seen = Set<String>(), out: [T] = []
            for x in local + server where seen.insert(key(x)).inserted { out.append(x) }
            return out
        }
        m.visits = union(s.visits, m.visits) { "\(Int($0.arrive))" }
        if m.points.isEmpty { m.points = s.points }
        if m.baro.isEmpty { m.baro = s.baro }
        m.acts = union(s.acts, m.acts) { "\(Int($0.ts))" }
        m.steps = union(s.steps, m.steps) { "\(Int($0.ts / 60_000))" }
        m.wifi = union(s.wifi, m.wifi) { "\(Int($0.ts))" }
        m.hk = union(s.hk, m.hk) { $0.uuid }
        // CarPlay: 앱이 보낸 것과 서버 사본(단축어 등)이 같은 연결이면(±120초) 하나로
        var car: [CalcInput.Car] = []
        for c in (m.car + s.car).sorted(by: { $0.ts < $1.ts }) {
            if car.contains(where: { $0.event == c.event && abs($0.ts - c.ts) <= 120_000 }) { continue }
            car.append(c)
        }
        m.car = car
        m.places = union(s.places, m.places) { "\($0.name)|\(Int($0.lat * 1e5))|\(Int($0.lon * 1e5))" }
        m.checkins = s.checkins
        // 주차: 서버(고친 층 포함) + 기기 (같은 시각이면 서버 값에 기기 좌표·높이)
        var parks = s.parks
        for p in m.parks {
            if let i = parks.firstIndex(where: { abs($0.ts - p.ts) < 2 }) {
                parks[i].lat = parks[i].lat ?? p.lat; parks[i].lon = parks[i].lon ?? p.lon
            } else { parks.append(p) }
        }
        m.parks = parks
        m.parkCal = union(s.parkCal, m.parkCal) { "\($0.lat)|\($0.lon)|\($0.dh)|\($0.level)" }
        m.floorCal = s.floorCal
        return applyEdits(m)
    }

    /// 기기에서 고친 것(주차 층·층 구간)을 서버보다 우선 — 보내기 전에도 바로 반영
    static func applyEdits(_ inp: CalcInput) -> CalcInput {
        var m = inp
        let edits = Archives.edits.days().flatMap { Archives.edits.items($0) }.sorted { $0.at < $1.at }
        for e in edits {
            switch e.kind {
            case "park":
                if let i = m.parks.firstIndex(where: { abs($0.ts - e.ts) < 2 }) {
                    m.parks[i].levelUser = e.level
                    let p = m.parks[i]
                    if let lv = e.level, let la = p.lat, let lo = p.lon {
                        let c = ParkCal(lat: la, lon: lo, dh: p.dh, level: lv)
                        if !m.parkCal.contains(c) { m.parkCal.append(c) }
                    }
                }
            case "floor":
                m.floorCal.removeAll { abs($0.ts - e.ts) < 2 }
                if let lv = e.level, let la = e.lat, let lo = e.lon, let dh = e.dh {
                    m.floorCal.append(.init(ts: e.ts, lat: la, lon: lo, dh: dh, level: lv, ap: e.ap))
                }
            default: break
            }
        }
        return m
    }

    // MARK: 계산·보관

    /// (화면용, 서버 보관용 JSON)
    static func compute(_ day: String) -> (TimelineDay, Data)? {
        let r = TimelineCalc.build(merged(day), date: day)
        guard let data = try? JSONEncoder().encode(r), let t = try? API.decode(TimelineDay.self, data) else { return nil }
        return (t, data)
    }

    struct ResultBody: Encodable { let result: CalcDay; let device: String }

    /// 결과를 서버에 보관 (바뀌었을 때만). 하루 기록을 하는 기기(아이폰)만
    static func upload(_ day: String) async {
        guard DaySettings.shared.prefs.enabled, !AppSettings.shared.token.isEmpty else { return }
        let r = TimelineCalc.build(merged(day), date: day)
        guard let data = try? JSONEncoder().encode(r) else { return }
        var h64: UInt64 = 0xcbf29ce484222325           // FNV-1a (앱을 다시 켜도 같은 값)
        for byte in data { h64 = (h64 ^ UInt64(byte)) &* 0x100000001b3 }
        let h = String(h64, radix: 16)
        var sent = (UserDefaults.standard.dictionary(forKey: "result.sent") as? [String: String]) ?? [:]
        if sent[day] == h { return }
        do {
            let _: OKResponse = try await API.send("PUT", "day/\(day)/result", body: ResultBody(result: r, device: "iPhone"))
            sent[day] = h
            if sent.count > 400 { sent = sent.filter { $0.key >= DayLogStore.dayKey((Date().timeIntervalSince1970 - 400 * 86400) * 1000) } }
            UserDefaults.standard.set(sent, forKey: "result.sent")
        } catch {}
    }

    private static var lastBg = Date.distantPast

    /// 백그라운드(업로드 때): 오늘·어제 보완 정보 받고 결과 보관 (15분에 한 번)
    static func backgroundSync() async {
        guard Date().timeIntervalSince(lastBg) > 900, !AppSettings.shared.token.isEmpty else { return }
        lastBg = Date()
        let now = Date().timeIntervalSince1970 * 1000
        for d in [fmt.string(from: Date(timeIntervalSince1970: now / 1000)), fmt.string(from: Date(timeIntervalSince1970: now / 1000 - 86400))] {
            do { try await refresh(d) } catch { return }
            await upload(d)
        }
    }

    static func today() -> String { fmt.string(from: Date()) }
}
