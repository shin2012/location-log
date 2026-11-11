import Foundation
import CoreMotion

/// 기압계 (CMAltimeter) 기록. 하루 종일 기록이 켜져 있는 동안 계속 받음 — 배터리 부담 거의 없음.
/// - 최근 2시간은 받은 값 전부 메모리에 (주차 층 계산용, Parking)
/// - 파일·서버에는 약 10cm(0.001 kPa) 넘게 바뀌었거나 1분 지났을 때만 (층 이동 분석용 day_baro)
/// 앱이 깨어 있어야 받음 → 하루 기록의 '앱 깨워 두기'가 그 역할. 권한은 '동작 및 피트니스'.
struct BaroSample: Codable, Sendable {
    let ts: Double      // epoch ms
    let kpa: Double
}

@MainActor
final class Baro: ObservableObject {
    static let shared = Baro()

    @Published private(set) var latest: BaroSample?
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastError: String?
    private(set) var on = false

    private let alt = CMAltimeter()
    private var ring: [BaroSample] = []
    private var lastSaved: BaroSample?
    private let dir: URL
    private var counts: [String: Int]
    private var uploaded: [String: Int]
    private var uploading = false

    private static let keepMs: Double = 2 * 3600 * 1000
    private static let saveStep = 0.001          // kPa ≈ 8 cm
    private static let saveEvery: Double = 60_000
    private static let countsKey = "baro.counts"
    private static let uploadedKey = "baro.uploaded"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("baro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        counts = (UserDefaults.standard.dictionary(forKey: Self.countsKey) as? [String: Int]) ?? [:]
        uploaded = (UserDefaults.standard.dictionary(forKey: Self.uploadedKey) as? [String: Int]) ?? [:]
    }

    static var available: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    func start() {
        guard !on, Self.available else { return }
        on = true
        alt.startRelativeAltitudeUpdates(to: .main) { [weak self] d, _ in
            guard let d else { return }
            let kpa = d.pressure.doubleValue
            MainActor.assumeIsolated { self?.ingest(kpa, at: Date()) }
        }
    }

    func stop() {
        guard on else { return }
        on = false
        alt.stopRelativeAltitudeUpdates()
        saveCounts()
    }

    private func ingest(_ kpa: Double, at d: Date) {
        let s = BaroSample(ts: (d.timeIntervalSince1970 * 1000).rounded(), kpa: kpa)
        latest = s
        ring.append(s)
        if ring.count > 600, let f = ring.first, s.ts - f.ts > Self.keepMs {
            ring.removeAll { s.ts - $0.ts > Self.keepMs }
        }
        if let l = lastSaved, abs(l.kpa - kpa) < Self.saveStep, s.ts - l.ts < Self.saveEvery { return }
        lastSaved = s
        append(s)
        WifiLog.shared.check()
    }

    /// t(epoch s) 앞뒤 5초 평균 기압. 그 근처(±30초)에 값이 없으면 nil
    func pressure(at t: Double) -> Double? {
        let ms = t * 1000
        let near = ring.filter { abs($0.ts - ms) <= 5000 }
        if !near.isEmpty { return near.map(\.kpa).reduce(0, +) / Double(near.count) }
        return ring.min(by: { abs($0.ts - ms) < abs($1.ts - ms) }).flatMap { abs($0.ts - ms) <= 30_000 ? $0.kpa : nil }
    }

    // MARK: 파일 (baro/YYYY-MM-DD.jsonl)

    private func file(_ day: String) -> URL { dir.appendingPathComponent("\(day).jsonl") }

    private func append(_ s: BaroSample) {
        let day = DayLogStore.dayKey(s.ts)
        let url = file(day)
        guard var line = try? JSONEncoder().encode(s) else { return }
        line.append(0x0A)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
            counts[day, default: 0] += 1
            if counts[day]! % 20 == 0 { saveCounts() }
        } catch {}
    }

    private func saveCounts() {
        UserDefaults.standard.set(counts, forKey: Self.countsKey)
        UserDefaults.standard.set(uploaded, forKey: Self.uploadedKey)
    }

    /// 그날(기기 시간대) 저장한 기압 — 타임라인 계산·업로드
    func samples(_ day: String) -> [BaroSample] {
        guard let d = try? Data(contentsOf: file(day)) else { return [] }
        let dec = JSONDecoder()
        return d.split(separator: 0x0A).compactMap { try? dec.decode(BaroSample.self, from: Data($0)) }
    }

    struct Body: Encodable { let samples: [BaroSample] }

    /// 올린 줄 수 다음부터 묶어 올림. 파일은 지우지 않음 (원본 보관)
    func upload(wifiOnly: Bool) async {
        guard !uploading, !AppSettings.shared.token.isEmpty else { return }
        uploading = true
        defer { uploading = false; saveCounts() }
        do {
            for day in counts.keys.sorted() {
                let total = counts[day] ?? 0
                var done = uploaded[day] ?? 0
                guard done < total else { continue }
                let v = samples(day)
                var i = min(done, v.count)
                while i < v.count {
                    let batch = Array(v[i..<min(v.count, i + 2000)])
                    let _: OKResponse = try await API.send("POST", "day/baro", body: Body(samples: batch), cellular: !wifiOnly)
                    i += batch.count
                    done = i
                    uploaded[day] = done
                }
                if v.count < total { counts[day] = v.count }
            }
            lastUploadAt = Date()
            lastError = nil
        } catch {
            lastError = "기압: " + error.localizedDescription
        }
    }
}
