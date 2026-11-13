import Foundation

/// 하루 타임라인 계산 — 시야쥬에서 유일한 계산 위치 (서버 server/timeline.py·floors.py·timefix.py 를 옮김, 1.9.0).
/// 순수 Foundation: 리눅스 swiftc 로 서버 결과와 대조 시험 (tools/calctest, tests/data/calc_*.json).
/// 입력 = 기기 보관함 + 서버 보완(받아 둔 것)을 합친 CalcInput. 시간 창(전날 12시간 등)은 여기서 거름 → 넉넉히 넣으면 됨.
/// 출력 JSON 은 서버 /api/day/{date}/timeline 과 같은 모양 → 앱은 TimelineDay 로 그대로 읽음.
/// 시각: 입력·출력 모두 epoch ms, 안에서는 초(Double).

// MARK: 입력

struct CalcInput: Codable {
    struct Visit: Codable { var arrive: Double; var depart: Double?; var lat: Double; var lon: Double }
    struct Point: Codable { var ts: Double; var lat: Double; var lon: Double; var src: String; var act: String? }
    struct Act: Codable { var ts: Double; var act: String }
    struct Step: Codable { var ts: Double; var steps: Int; var up: Int?; var down: Int? }
    struct Car: Codable { var ts: Double; var event: String }
    struct Place: Codable { var name: String; var lat: Double; var lon: Double; var radius: Double }
    struct Checkin: Codable { var ts: Double; var name: String; var lat: Double; var lon: Double }
    struct Park: Codable { var ts: Double; var lat: Double?; var lon: Double?; var dh: Double; var levelEst: Int; var levelUser: Int? }
    struct Baro: Codable { var ts: Double; var kpa: Double }
    struct FloorCal: Codable { var ts: Double; var lat: Double; var lon: Double; var dh: Double; var level: Int; var ap: String? }
    struct Wifi: Codable { var ts: Double; var bssid: String? }
    struct Hk: Codable { var uuid: String; var kind: String; var start: Double; var end: Double; var value: Double; var device: String }
    struct FloorProfile: Codable {
        struct Anchor: Codable { var dh: Double; var level: Int }
        var lat: Double; var lon: Double; var radius: Double; var anchors: [Anchor]
    }

    var day0: Double            // 하루 시작 (한국 0시) epoch ms
    var day1: Double
    var now: Double             // 머무는 중(depart 없음) 끝 시각
    var visits: [Visit] = []
    var points: [Point] = []
    var acts: [Act] = []
    var steps: [Step] = []
    var car: [Car] = []
    var places: [Place] = []
    var checkins: [Checkin] = []
    var parks: [Park] = []
    var parkCal: [ParkCal] = []   // 사용자가 확정한 주차 전부 (장소별 층 높이)
    var baro: [Baro] = []
    var floorCal: [FloorCal] = []
    var wifi: [Wifi] = []
    var hk: [Hk] = []
    var floorProfiles: [FloorProfile] = []
}

/// 빠진 목록은 빈 목록으로 (서버는 기기에 이미 있는 위치 점·기압을 빼고 보냄 — 키가 없어도 읽혀야 함)
extension CalcInput {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func l<T: Decodable>(_ k: CodingKeys) throws -> [T] { try c.decodeIfPresent([T].self, forKey: k) ?? [] }
        self.init(day0: try c.decode(Double.self, forKey: .day0), day1: try c.decode(Double.self, forKey: .day1),
                  now: try c.decode(Double.self, forKey: .now))
        visits = try l(.visits); points = try l(.points); acts = try l(.acts); steps = try l(.steps); car = try l(.car)
        places = try l(.places); checkins = try l(.checkins); parks = try l(.parks); parkCal = try l(.parkCal)
        baro = try l(.baro); floorCal = try l(.floorCal); wifi = try l(.wifi); hk = try l(.hk)
        floorProfiles = try l(.floorProfiles)
    }
}

// MARK: 출력 (서버 JSON 과 같은 키)

struct CalcDay: Encodable {
    struct Sub: Encodable { var kind: String; var start: Double; var end: Double; var dh: Double?; var level: Int; var est: Bool?; var label: String }
    struct Floor: Encodable {
        var start: Double; var end: Double; var dh: Double; var via: String?; var ap: String?
        var level: Int; var est: Bool; var label: String; var subs: [Sub]
    }
    struct Park: Encodable { var ts: Double; var level: Int; var label: String; var est: Bool }
    struct Item: Encodable {
        var kind: String
        var start: Double
        var end: Double
        var lat: Double? = nil, lon: Double? = nil, name: String? = nil, checkin: Bool? = nil, open: Bool? = nil, minutes: Int? = nil
        var floors: [Floor]? = nil
        var subs: [Sub]? = nil
        var km: Double? = nil, mode: String? = nil, drove: Bool? = nil, steps: Int? = nil, est: Bool? = nil
        var path: [[Double]]? = nil
        var park: Park? = nil
    }
    struct Summary: Encodable { var km: Double; var steps: Int; var driveMin: Int; var visits: Int
        enum CodingKeys: String, CodingKey { case km, steps, driveMin = "drive_min", visits }
    }
    var date: String
    var items: [Item]
    var summary: Summary
}

// MARK: 계산

enum TimelineCalc {
    static let mergeKm = 0.1, insideKm = 0.2, mergeGap = 600.0, runGap = 900.0, jumpMps = 70.0
    static let pathSrc: Set<String> = ["gps", "fill", "trk", "imu"]
    static let moving: Set<String> = ["walk", "run", "bike", "car"]
    static let parkAfter = 1200.0

    static func havKm(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = Double.pi / 180
        let la1 = a.0 * r, lo1 = a.1 * r, la2 = b.0 * r, lo2 = b.1 * r
        let h = pow(sin((la2 - la1) / 2), 2) + cos(la1) * cos(la2) * pow(sin((lo2 - lo1) / 2), 2)
        return 2 * 6371.0088 * asin(min(1, h.squareRoot()))
    }

    /// 파이썬 round 와 같게: 2진수 값을 정확히 십진으로 반올림(printf 와 같은 방식) — 곱해서 반올림하면 끝자리가 가끔 다름
    static func pyRound(_ x: Double, _ nd: Int = 0) -> Double {
        if nd == 0 { return x.rounded(.toNearestOrEven) }
        return Double(String(format: "%.\(nd)f", x)) ?? x
    }

    // 내부 표현 (초)
    struct V { var start: Double; var end: Double; var lat: Double; var lon: Double; var open: Bool; var len: Double = 0 }
    struct P { var ts: Double; var lat: Double; var lon: Double; var src: String; var act: String? }
    struct A { var ts: Double; var act: String }
    struct S { var ts: Double; var steps: Int; var up: Int?; var down: Int? }
    struct K { var ts: Double; var level: Int; var est: Bool; var dh: Double?; var id: Int }

    /// CalcInput → 서버 /timeline 과 같은 JSON 구조
    static func build(_ inp: CalcInput, date: String) -> CalcDay {
        let a = inp.day0 / 1000, b = inp.day1 / 1000
        // 서버 app.py day_timeline 의 조회 창과 같게 거름
        let vsRaw = inp.visits.filter { $0.arrive / 1000 < b && ($0.depart == nil || $0.depart! / 1000 > a - 43200) }
            .sorted { $0.arrive < $1.arrive }
            .map { V(start: $0.arrive / 1000, end: ($0.depart ?? inp.now) / 1000, lat: $0.lat, lon: $0.lon, open: $0.depart == nil) }
        let pts = inp.points.filter { $0.ts / 1000 >= a && $0.ts / 1000 < b && pathSrc.contains($0.src) }
            .sorted { $0.ts < $1.ts }.map { P(ts: $0.ts / 1000, lat: $0.lat, lon: $0.lon, src: $0.src, act: $0.act) }
        let actsAll = inp.acts.sorted { $0.ts < $1.ts }.map { A(ts: $0.ts / 1000, act: $0.act) }
        var acts = actsAll.filter { $0.ts >= a && $0.ts < b }
        if let last = actsAll.last(where: { $0.ts < a }) { acts.insert(last, at: 0) }
        let steps = inp.steps.filter { $0.ts / 1000 >= a && $0.ts / 1000 < b }.sorted { $0.ts < $1.ts }
            .map { S(ts: $0.ts / 1000, steps: $0.steps, up: $0.up, down: $0.down) }
        let car = inp.car.filter { $0.ts / 1000 >= a - 21600 && $0.ts / 1000 < b }.sorted { $0.ts < $1.ts }
        let cks = inp.checkins.filter { $0.ts / 1000 >= a - 43200 && $0.ts / 1000 < b }.sorted { $0.ts < $1.ts }
        var parks: [K] = []
        for (i, r) in inp.parks.filter({ $0.ts / 1000 >= a - 3600 && $0.ts / 1000 < b + 3600 }).sorted(by: { $0.ts < $1.ts }).enumerated() {
            if let u = r.levelUser {
                parks.append(K(ts: r.ts / 1000, level: u, est: false, dh: r.dh, id: i))
            } else if let la = r.lat, let lo = r.lon {
                parks.append(K(ts: r.ts / 1000, level: ParkModel.estimate(dh: r.dh, lat: la, lon: lo, cal: inp.parkCal), est: true, dh: r.dh, id: i))
            } else {
                parks.append(K(ts: r.ts / 1000, level: r.levelEst, est: true, dh: r.dh, id: i))
            }
        }
        let baro = inp.baro.filter { $0.ts / 1000 >= a - 3600 && $0.ts / 1000 < b }.sorted { $0.ts < $1.ts }
        let wifiAll = inp.wifi.sorted { $0.ts < $1.ts }
        var wifi = wifiAll.filter { $0.ts / 1000 >= a && $0.ts / 1000 < b }.map { Floors.W(ts: $0.ts / 1000, bssid: $0.bssid) }
        if let l = wifiAll.last(where: { $0.ts / 1000 < a }) { wifi.insert(Floors.W(ts: l.ts / 1000, bssid: l.bssid), at: 0) }
        let hk = inp.hk.filter { $0.end / 1000 >= a && $0.start / 1000 < b }.sorted { $0.start < $1.start }
            .map { Floors.H(kind: $0.kind, start: $0.start / 1000, end: $0.end / 1000, value: $0.value, device: $0.device) }
        let fcal = inp.floorCal.map { Floors.Cal(ts: $0.ts / 1000, lat: $0.lat, lon: $0.lon, dh: $0.dh, level: $0.level, ap: $0.ap) }

        var visits = mergeVisits(vsRaw)
        // 떠난 시각 = 움직이기 시작한 때
        for i in visits.indices where !visits[i].open {
            if let ms = moveStart(acts, visits[i].end, notBefore: visits[i].start), visits[i].start < ms, ms < visits[i].end {
                visits[i].end = ms
            }
        }
        // 이름: 스웜 체크인 (들어오기 10분 전 ~ 나가고 30분 뒤, 200m 안 가장 가까운 머묾)
        var names: [Int: CalcInput.Checkin] = [:]
        var best: [Int: Double] = [:]
        for c in cks {
            let t = c.ts / 1000
            var cand: [(Double, Int)] = []
            for (i, v) in visits.enumerated() where v.start - 600 <= t && t <= v.end + 1800 {
                let d = havKm((c.lat, c.lon), (v.lat, v.lon))
                if d <= 0.2 { cand.append((d, i)) }
            }
            guard let m = cand.min(by: { $0.0 < $1.0 }) else { continue }
            if m.0 < (best[m.1] ?? 9) { best[m.1] = m.0; names[m.1] = c }
        }
        var items: [(CalcDay.Item, Int)] = []   // (항목, 넣은 순서) — 같은 시각이면 넣은 순서 (파이썬 안정 정렬)
        let hs = Floors.heights(baro.map { ($0.ts / 1000, $0.kpa) })
        for (i, v) in visits.enumerated() {
            if v.end <= a || v.start >= b { continue }
            let s = max(v.start, a), e = min(v.end, b)
            let ck = names[i]
            let pl = inp.places.first { havKm(($0.lat, $0.lon), (v.lat, v.lon)) * 1000 <= max(150, $0.radius * 1.5) }
            var it = CalcDay.Item(kind: "visit", start: s, end: e, lat: v.lat, lon: v.lon, name: ck?.name ?? pl?.name,
                                  checkin: ck != nil, open: v.open, minutes: Int(pyRound((e - s) / 60)))
            if !hs.isEmpty || !hk.isEmpty {
                let pk = parks.filter { v.start - parkAfter <= $0.ts && $0.ts <= v.start + 300 && $0.dh != nil }
                let base = pk.last?.dh ?? 0
                let profile = inp.floorProfiles.first { ParkModel.dist(v.lat, v.lon, $0.lat, $0.lon) <= $0.radius }
                let segs: [CalcDay.Floor]
                if let profile {
                    let localPark = inp.parks.filter { p in
                        guard let la = p.lat, let lo = p.lon else { return false }
                        return v.start - parkAfter <= p.ts / 1000 && p.ts / 1000 <= v.start + 300
                            && ParkModel.dist(la, lo, profile.lat, profile.lon) <= profile.radius
                    }.max { $0.ts < $1.ts }
                    segs = Floors.profileSegments(start: s, end: e, hs: hs, steps: steps,
                                                  profile: profile, parkAt: localPark.map { $0.ts / 1000 })
                } else {
                    segs = Floors.segments(start: s, end: e, lat: v.lat, lon: v.lon, hs: hs, steps: steps, cal: fcal,
                                           wifi: wifi, baseDh: base, hk: hk)
                }
                if segs.count > 1 { it.floors = segs } else if let f = segs.first, !f.subs.isEmpty { it.subs = f.subs }
            }
            items.append((it, items.count))
        }
        // 운전 = CarPlay 연결 구간
        var sessions: [(Double, Double)] = []
        var on: Double?
        for c in car {
            if c.event == "car_start" { on = on ?? c.ts / 1000 }
            else if c.event == "car_end", let o = on { sessions.append((o, c.ts / 1000)); on = nil }
        }
        if let o = on { sessions.append((o, b)) }
        var movesKm = 0.0, driveMin = 0.0
        var used = Set<Int>()
        for r in runs(pts, visits) {
            guard r.count >= 2, r.last!.ts >= a, r.first!.ts < b else { continue }
            var km = 0.0
            for j in 1..<r.count { km += havKm((r[j - 1].lat, r[j - 1].lon), (r[j].lat, r[j].lon)) }
            if km < 0.05 { continue }
            var t0 = r.first!.ts
            let t1 = r.last!.ts
            if let pe = visits.map(\.end).filter({ $0 <= t0 && t0 - $0 <= mergeGap }).max() { t0 = pe }
            var mode = moveMode(r, acts, steps)
            let drove = sessions.contains { $0.0 <= t1 && t0 <= $0.1 }
            if drove { mode = "car" }
            let st = steps.filter { t0 <= $0.ts && $0.ts <= t1 }.reduce(0) { $0 + $1.steps }
            var it = CalcDay.Item(kind: "move", start: t0, end: t1, km: pyRound(km, 2), mode: mode, drove: drove, steps: st,
                                  est: r.contains { $0.src == "imu" },
                                  path: simplify(r.map { [pyRound($0.lat, 6), pyRound($0.lon, 6)] }))
            if drove {
                let pk = parks.filter { t0 <= $0.ts && $0.ts <= t1 + parkAfter && !used.contains($0.id) }
                if let k = pk.min(by: { abs($0.ts - t1) < abs($1.ts - t1) }) {
                    used.insert(k.id)
                    it.park = .init(ts: k.ts, level: k.level, label: ParkModel.label(k.level), est: k.est)
                }
            }
            items.append((it, items.count))
            movesKm += km
            if drove { driveMin += (t1 - t0) / 60 }
        }
        let sorted = items.sorted { $0.0.start != $1.0.start ? $0.0.start < $1.0.start : $0.1 < $1.1 }.map(\.0)
        let total = steps.filter { a <= $0.ts && $0.ts < b }.reduce(0) { $0 + $1.steps }
        let out = sorted.map(toMs)
        return CalcDay(date: date, items: out, summary: .init(km: pyRound(movesKm, 1), steps: total, driveMin: Int(pyRound(driveMin)),
                                                              visits: out.filter { $0.kind == "visit" }.count))
    }

    /// 초 → ms (서버 dt_to_ms 처럼 정수 ms)
    static func toMs(_ it: CalcDay.Item) -> CalcDay.Item {
        func ms(_ t: Double) -> Double { (t * 1000).rounded() }   // 입력이 정수 ms → 되돌릴 때 부동소수 오차 없게
        var x = it
        x.start = ms(it.start); x.end = ms(it.end)
        x.park?.ts = ms(it.park?.ts ?? 0)
        x.floors = it.floors?.map { f in
            var g = f; g.start = ms(f.start); g.end = ms(f.end)
            g.subs = f.subs.map { var s = $0; s.start = ms($0.start); s.end = ms($0.end); return s }
            return g
        }
        x.subs = it.subs?.map { var s = $0; s.start = ms($0.start); s.end = ms($0.end); return s }
        return x
    }

    static func mergeVisits(_ vs: [V]) -> [V] {
        var out: [V] = []
        for v in vs.sorted(by: { $0.start < $1.start }) {
            if var p = out.last, v.start - p.end <= mergeGap, havKm((p.lat, p.lon), (v.lat, v.lon)) <= mergeKm {
                if v.end - v.start > p.len { p.lat = v.lat; p.lon = v.lon; p.len = v.end - v.start }
                p.end = max(p.end, v.end)
                p.open = p.open || v.open
                out[out.count - 1] = p
                continue
            }
            var n = v; n.len = v.end - v.start
            out.append(n)
        }
        return out
    }

    static func runs(_ pts: [P], _ visits: [V]) -> [[P]] {
        func inside(_ p: P) -> Bool {
            visits.contains { $0.start <= p.ts && p.ts <= $0.end && havKm(($0.lat, $0.lon), (p.lat, p.lon)) <= insideKm }
        }
        var out: [[P]] = [], cur: [P] = []
        for p in pts {
            if inside(p) {
                if !cur.isEmpty { out.append(cur) }
                cur = []
                continue
            }
            if let q = cur.last {
                let dt = p.ts - q.ts
                if dt > runGap { out.append(cur); cur = [] }
                else if dt > 0 && havKm((q.lat, q.lon), (p.lat, p.lon)) * 1000 / dt > jumpMps { continue }
            }
            cur.append(p)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 방식별 초 (넣은 순서 유지 — 파이썬 dict 순서와 같게 동점 처리)
    static func actDurations(_ acts: [A], _ t0: Double, _ t1: Double) -> [(String, Double)] {
        var keys: [String] = [], dur: [String: Double] = [:]
        for (i, x) in acts.enumerated() {
            let s = max(x.ts, t0), e = min(i + 1 < acts.count ? acts[i + 1].ts : t1, t1)
            if e > s {
                let k = x.act == "run" ? "walk" : x.act
                if dur[k] == nil { keys.append(k) }
                dur[k, default: 0] += e - s
            }
        }
        return keys.map { ($0, dur[$0]!) }
    }

    /// 파이썬 max(d, key=d.get): 가장 큰 값 중 먼저 넣은 것
    static func firstMax<T: Comparable>(_ xs: [(String, T)]) -> String? {
        var best: (String, T)?
        for x in xs where best == nil || x.1 > best!.1 { best = x }
        return best?.0
    }

    static func moveMode(_ run: [P], _ acts: [A], _ steps: [S]) -> String {
        let t0 = run.first!.ts, t1 = run.last!.ts
        let dur = actDurations(acts, t0, t1).filter { ["car", "walk", "bike"].contains($0.0) && $0.1 >= 120 }
        if let m = firstMax(dur) { return m }
        var keys: [String] = [], pd: [String: Int] = [:]
        for p in run {
            if let a = p.act, moving.contains(a) {
                let k = a == "run" ? "walk" : a
                if pd[k] == nil { keys.append(k) }
                pd[k, default: 0] += 1
            }
        }
        if let m = firstMax(keys.map { ($0, pd[$0]!) }) { return m }
        if steps.filter({ t0 <= $0.ts && $0.ts <= t1 && $0.steps >= 60 }).count >= 3 { return "walk" }
        let secs = t1 - t0
        var km = 0.0
        for j in 1..<run.count { km += havKm((run[j - 1].lat, run[j - 1].lon), (run[j].lat, run[j].lon)) }
        if secs > 0 && km / (secs / 3600) >= 20 { return "car" }
        return "unknown"
    }

    static func simplify(_ path: [[Double]], _ n: Int = 300) -> [[Double]] {
        if path.count <= n { return path }
        let step = Double(path.count) / Double(n)
        return (0..<n).map { path[Int(Double($0) * step)] } + [path.last!]
    }

    /// timefix.move_start: at 에 이어지던 움직임이 시작된 시각 (짧은 멈춤 2분 미만은 이어진 것으로)
    static func moveStart(_ acts: [A], _ at: Double, notBefore: Double?) -> Double? {
        var lo = at - 600
        if let nb = notBefore, nb > lo { lo = nb }
        let before = acts.filter { $0.ts <= at }
        if before.isEmpty { return nil }
        var start: Double?
        var i = before.count - 1
        while i >= 0 {
            let x = before[i]
            if x.ts < lo { break }
            if moving.contains(x.act) { start = x.ts; i -= 1; continue }
            let end = i + 1 < before.count ? before[i + 1].ts : at
            if end - x.ts >= 120 { break }
            i -= 1
        }
        return start
    }
}

// MARK: 층 (server/floors.py)

enum Floors {
    static let jumpM = 2.5, maxDur = 240.0, platRange = 0.6, platMinS = 20.0, elevMps = 0.5, stepRise = 0.17
    static let defA = 3.5, defG1 = 4.5, before = 180.0
    static let watchFloorM = 3.0, phoneStill = 5, watchWalk = 10.0

    struct W { var ts: Double; var bssid: String? }
    struct H { var kind: String; var start: Double; var end: Double; var value: Double; var device: String }
    struct Cal { var ts: Double; var lat: Double; var lon: Double; var dh: Double; var level: Int; var ap: String? }
    struct Plat { var start: Double; var end: Double; var first: Double; var last: Double }
    struct Ev { var start: Double; var end: Double; var dh: Double; var mps: Double }

    static func heights(_ baro: [(Double, Double)]) -> [(Double, Double)] {
        guard let p0 = baro.first?.1 else { return [] }
        return baro.map { ($0.0, ParkModel.hScale * log(p0 / $0.1)) }
    }

    static func med3(_ v: ArraySlice<Double>) -> Double { let s = v.sorted(); return s[s.count / 2] }

    static func plateaus(_ hs: [(Double, Double)]) -> [Plat] {
        var out: [Plat] = []
        var i = 0
        let n = hs.count
        while i < n {
            var lo = hs[i].1, hi = hs[i].1, j = i
            while j + 1 < n {
                let v = hs[j + 1].1
                if max(hi, v) - min(lo, v) > platRange { break }
                lo = min(lo, v); hi = max(hi, v); j += 1
            }
            if hs[j].0 - hs[i].0 >= platMinS {
                let vals = hs[i...j].map(\.1)
                out.append(Plat(start: hs[i].0, end: hs[j].0, first: med3(vals.prefix(3)), last: med3(vals.suffix(3))))
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    static func detect(_ hs: [(Double, Double)]) -> [Ev] {
        let ps = plateaus(hs)
        var out: [Ev] = []
        guard ps.count > 1 else { return out }
        for k in 1..<ps.count {
            let a = ps[k - 1], b = ps[k]
            let dh = b.first - a.last
            if abs(dh) >= jumpM && b.start - a.end <= maxDur {
                out.append(Ev(start: a.end, end: b.start, dh: dh, mps: midSpeed(hs, a, b, dh)))
            }
        }
        return out
    }

    static func midSpeed(_ hs: [(Double, Double)], _ a: Plat, _ b: Plat, _ dh: Double) -> Double {
        let seg = hs.filter { a.end <= $0.0 && $0.0 <= b.start }
        let lo = a.last + dh * 0.2, hi = a.last + dh * 0.8
        let sign = dh > 0 ? 1.0 : -1.0
        guard let t20 = seg.first(where: { ($0.1 - lo) * sign >= 0 })?.0,
              let t80 = seg.first(where: { ($0.1 - hi) * sign >= 0 })?.0 else {
            return abs(dh) / max(1, b.start - a.end)
        }
        return abs(dh) * 0.6 / max(1, t80 - t20)
    }

    static func minute(_ t: Double) -> Double { (t / 60).rounded(.down) * 60 }

    static func classify(_ e: Ev, _ steps: [TimelineCalc.S]) -> String {
        let s0 = minute(e.start)
        let mins = steps.filter { s0 <= $0.ts && $0.ts <= e.end }
        if mins.contains(where: { ($0.up ?? 0) + ($0.down ?? 0) > 0 }) { return "stairs" }
        let v = e.mps > 0 ? e.mps : abs(e.dh) / max(1, e.end - e.start)
        if v >= elevMps { return "elevator" }
        let st = mins.reduce(0) { $0 + $1.steps }
        if Double(st) >= abs(e.dh) / stepRise * 0.6 { return "stairs" }
        return "escalator"
    }

    static func ap(_ bssid: String?) -> String? {
        guard let b = bssid, !b.isEmpty else { return nil }
        let p = b.lowercased().split(separator: ":", omittingEmptySubsequences: false).map { $0.count < 2 ? String(repeating: "0", count: 2 - $0.count) + $0 : String($0) }
        return p.count == 6 ? p.prefix(5).joined(separator: ":") : b.lowercased()
    }

    static func wifiAt(_ wifi: [W], _ a: Double, _ b: Double) -> String? {
        var keys: [String] = [], dur: [String: Double] = [:]
        for (i, w) in wifi.enumerated() {
            let s = max(w.ts, a), e = min(i + 1 < wifi.count ? wifi[i + 1].ts : b, b)
            if let k = ap(w.bssid), e > s {
                if dur[k] == nil { keys.append(k) }
                dur[k, default: 0] += e - s
            }
        }
        return TimelineCalc.firstMax(keys.map { ($0, dur[$0]!) })
    }

    static func phoneSum(_ ph: [Double: Int], _ a: Double, _ b: Double) -> Int {
        var m = minute(a), n = 0
        while m < b { n += ph[m] ?? 0; m += 60 }
        return n
    }

    struct Exc { var start: Double; var end: Double; var floors: Double }

    static func excursions(start vs: Double, end ve: Double, steps: [TimelineCalc.S], hk: [H], evs: [Ev]) -> [Exc] {
        var ph: [Double: Int] = [:]
        for s in steps { ph[s.ts] = s.steps }
        let chunks = hk.filter { $0.kind == "steps" && $0.device == "watch" }.sorted { $0.start < $1.start }
        let fl = hk.filter { $0.kind == "flights" && $0.device == "watch" && vs <= $0.start && $0.start < ve && $0.value >= 1 }
            .sorted { $0.start < $1.start }
        let phKeys = ph.keys.sorted()
        var out: [Exc] = []
        for f in fl {
            if let l = out.last, f.start < l.end { out[out.count - 1].floors += f.value; continue }
            if phoneSum(ph, f.start - 60, f.end + 60) >= phoneStill { continue }
            if evs.contains(where: { $0.start - 60 <= f.end && f.start <= $0.end + 60 }) { continue }
            let ret = chunks.first { $0.start >= f.end + 120 && $0.value >= watchWalk }?.start
            let moved = phKeys.first { $0 > f.end && (ph[$0] ?? 0) >= phoneStill }
            let end = [ret, moved, ve].compactMap { $0 }.min()!
            out.append(Exc(start: f.end, end: end, floors: f.value))
        }
        return out
    }

    static func defaultLevel(_ dh: Double) -> Int {
        var n: Int
        if dh >= defG1 { n = 1 + Int(((dh - defG1) / defA + 0.5).rounded(.down)) }
        else if dh >= 0 { n = dh >= defG1 / 2 ? 1 : 0 }
        else { n = Int((dh / defA + 0.5).rounded(.down)) }
        return max(ParkModel.levelMin, min(ParkModel.levelMax, n))
    }

    static func levelOf(_ dh: Double, _ lat: Double, _ lon: Double, _ near: [Cal]) -> Int {
        if near.isEmpty { return defaultLevel(dh) }
        let (a, b) = ParkModel.model(lat: lat, lon: lon, cal: near.map { ParkCal(lat: $0.lat, lon: $0.lon, dh: $0.dh, level: $0.level) }, defA: defA)
        return max(ParkModel.levelMin, min(ParkModel.levelMax, Int(((dh - b) / a + 0.5).rounded(.down))))
    }

    /// 주차 시각을 기준으로 한 장소별 상대 높이. 도로·기존 보정·공유기 기준과 섞지 않는다.
    static func profileSegments(start vs: Double, end ve: Double, hs: [(Double, Double)], steps: [TimelineCalc.S],
                                profile: CalcInput.FloorProfile, parkAt: Double?) -> [CalcDay.Floor] {
        guard let parkAt, parkAt < ve, !profile.anchors.isEmpty else { return [] }
        let nearby = hs.filter { abs($0.0 - parkAt) <= 60 }
        guard let closest = nearby.min(by: { abs($0.0 - parkAt) < abs($1.0 - parkAt) }) else { return [] }
        let refs = nearby.filter { 5 <= $0.0 - parkAt && $0.0 - parkAt <= 35 }.map(\.1).sorted()
        let ref = refs.isEmpty ? closest.1 : refs[refs.count / 2]
        var win = hs.filter { parkAt <= $0.0 && $0.0 <= ve }
        if win.count > 1, let gap = (1..<win.count).first(where: { win[$0].0 - win[$0 - 1].0 > 90 }) {
            win = Array(win.prefix(gap))
        }
        guard let first = win.first, first.0 - parkAt <= 60, let last = win.last else { return [] }
        let ps = plateaus(win)
        guard !ps.isEmpty else { return [] }
        func level(_ dh: Double) -> Int? {
            guard let a = profile.anchors.min(by: { abs($0.dh - dh) < abs($1.dh - dh) }), abs(a.dh - dh) <= 4.5 else { return nil }
            return a.level
        }
        var t = max(vs, parkAt), dh = 0.0, lv = level(0)
        var via: String?
        var out: [CalcDay.Floor] = []
        func emit(_ end: Double) {
            guard end > t, let lv else { return }
            if let l = out.last, l.level == lv {
                out[out.count - 1].end = end
            } else {
                out.append(.init(start: t, end: end, dh: TimelineCalc.pyRound(dh, 2), via: via,
                                 ap: nil, level: lv, est: true, label: ParkModel.label(lv), subs: []))
            }
        }
        if ps.count > 1 {
            for k in 1..<ps.count {
                let a = ps[k - 1], b = ps[k], delta = b.first - a.last
                if abs(delta) < jumpM || b.start - a.end > maxDur { continue }
                emit(max(t, a.end))
                let previous = lv
                dh = b.first - ref; t = max(vs, b.start); lv = level(dh)
                let top = profile.anchors.map(\.level).max()!
                if previous == top, delta <= -10, let next = lv, next < 0,
                   profile.anchors.contains(where: { $0.level == 0 }) { lv = 0 }
                let ev = Ev(start: a.end, end: b.start, dh: delta, mps: midSpeed(win, a, b, delta))
                via = ev.mps >= elevMps || (abs(delta) >= 10 && (lv == top || previous == top)) ? "elevator" : "stairs"
            }
        }
        emit(min(ve, last.0))
        return out
    }

    static func segments(start vs: Double, end ve: Double, lat: Double, lon: Double, hs: [(Double, Double)], steps: [TimelineCalc.S],
                         cal: [Cal], wifi: [W], baseDh: Double, hk: [H]) -> [CalcDay.Floor] {
        let win = hs.filter { vs - before - 120 <= $0.0 && $0.0 <= ve }
        let evs = detect(win).filter { $0.start >= vs - before }
        let exc = excursions(start: vs, end: ve, steps: steps, hk: hk, evs: evs)
        if evs.isEmpty && exc.isEmpty { return [] }
        let near = cal.filter { ParkModel.dist(lat, lon, $0.lat, $0.lon) <= ParkModel.nearM }
        func hit(_ t: Double) -> Cal? { near.first { abs($0.ts - t) < 1 } }
        var apKeys: [String] = [], apLv: [String: [Int]] = [:]
        for c in near { if let a = c.ap { if apLv[a] == nil { apKeys.append(a) }; apLv[a, default: []].append(c.level) } }
        var out: [CalcDay.Floor] = []
        var t = vs, dh = baseDh
        var via: String?
        let all: [Ev?] = evs.map { Optional($0) } + [nil]
        for e in all {
            let end = e?.start ?? ve
            if end > t || out.isEmpty {
                let w = wifi.isEmpty ? nil : wifiAt(wifi, t, max(end, t))
                var level: Int, est: Bool
                if let h = hit(t) { level = h.level; est = false }
                else if let w, let l = apLv[w], l.count >= 2, Set(l).count == 1 { level = l[0]; est = true }
                else { level = levelOf(dh, lat, lon, near); est = true }
                out.append(.init(start: t, end: max(end, t), dh: TimelineCalc.pyRound(dh, 2), via: via, ap: w,
                                 level: level, est: est, label: ParkModel.label(level), subs: []))
            }
            if let e {
                dh += e.dh
                t = e.end
                via = classify(e, steps)
            }
        }
        var merged: [CalcDay.Floor] = []
        for sg in out {
            if let l = merged.last, l.level == sg.level { merged[merged.count - 1].end = sg.end; continue }
            merged.append(sg)
        }
        for x in exc {
            guard let i = merged.firstIndex(where: { $0.start <= x.start && x.start < $0.end }) else { continue }
            let sg = merged[i]
            let h = hit(x.start)
            let lv = h?.level ?? sg.level + Int(x.floors)
            merged[i].subs.append(.init(kind: "floor", start: x.start, end: x.end, dh: TimelineCalc.pyRound(sg.dh + x.floors * watchFloorM, 2),
                                        level: lv, est: h == nil, label: ParkModel.label(lv)))
            if x.end < sg.end {
                merged[i].subs.append(.init(kind: "back", start: x.end, end: x.end, dh: nil, level: sg.level, est: nil, label: sg.label))
            }
        }
        for i in merged.indices {
            merged[i].subs = merged[i].subs.enumerated().sorted {
                ($0.element.start, $0.element.kind == "back" ? 1 : 0, $0.offset) < ($1.element.start, $1.element.kind == "back" ? 1 : 0, $1.offset)
            }.map(\.element)
        }
        return merged
    }
}
