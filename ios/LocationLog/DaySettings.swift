import Foundation

/// 하루 종일 기록 설정 (UserDefaults "day.prefs" 에 JSON으로 보관)
struct DayPrefs: Codable, Equatable {
    struct Place: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var name: String
        var lat: Double
        var lon: Double
        var radius: Double = 150
    }

    var enabled = false
    var level: DayLevel = .balanced
    // 출발 알아채기 (각각 끌 수 있음)
    var keepAlive = true          // 머무는 동안 저정확도 위치로 앱 깨워 두기
    var motionWake = true         // 움직임 감지
    var checkMinutes = 10         // GPS 확인 간격, 0 = 끔
    var fillGap = true            // 출발 구간 메우기
    var regionWake = true         // 경계·방문·기지국 변화 감지 (앱이 꺼졌을 때 다시 깨움)
    // 세부
    var geofenceRadius: Double = 150
    var stayMinutes = 5
    var stayRadius: Double = 100
    var movingDistance: Double = 0
    // 배터리
    var lowPowerSave = true       // 저전력 모드·20% 이하 → 절약, 주기 확인 끔
    var showIndicator = true      // 상단 파란 위치 표시
    // 업로드
    var uploadMinutes = 30
    var wifiOnly = false
    // 쉬는 시간
    var quietOn = false
    var quietStart = 0            // 시
    var quietEnd = 7
    var excluded: [Place] = []
    var keepDays = 90             // 이 기기 보관

    init() {}

    // 새 항목이 생겨도 예전 저장값을 읽을 수 있게 하나하나 기본값으로
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = DayPrefs()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil ?? def }
        enabled = v(.enabled, z.enabled); level = v(.level, z.level)
        keepAlive = v(.keepAlive, z.keepAlive); motionWake = v(.motionWake, z.motionWake)
        checkMinutes = v(.checkMinutes, z.checkMinutes); fillGap = v(.fillGap, z.fillGap)
        regionWake = v(.regionWake, z.regionWake); geofenceRadius = v(.geofenceRadius, z.geofenceRadius)
        stayMinutes = v(.stayMinutes, z.stayMinutes); stayRadius = v(.stayRadius, z.stayRadius)
        movingDistance = v(.movingDistance, z.movingDistance); lowPowerSave = v(.lowPowerSave, z.lowPowerSave)
        showIndicator = v(.showIndicator, z.showIndicator); uploadMinutes = v(.uploadMinutes, z.uploadMinutes)
        wifiOnly = v(.wifiOnly, z.wifiOnly); quietOn = v(.quietOn, z.quietOn)
        quietStart = v(.quietStart, z.quietStart); quietEnd = v(.quietEnd, z.quietEnd)
        excluded = v(.excluded, z.excluded); keepDays = v(.keepDays, z.keepDays)
    }

    /// 쉬는 시간대인지 (예: 0~7시, 23~6시처럼 자정을 넘는 것도)
    func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard quietOn, quietStart != quietEnd else { return false }
        let h = calendar.component(.hour, from: date)
        return quietStart < quietEnd ? (h >= quietStart && h < quietEnd) : (h >= quietStart || h < quietEnd)
    }

    func isExcluded(lat: Double, lon: Double) -> Bool {
        excluded.contains { DayGeo.dist($0.lat, $0.lon, lat, lon) <= $0.radius }
    }

    func policyOptions(lowBattery: Bool) -> DayPolicy.Options {
        var o = DayPolicy.Options()
        o.level = level
        o.keepAlive = keepAlive
        o.motionWake = motionWake
        o.checkMinutes = checkMinutes
        o.fillGap = fillGap
        o.stayMinutes = stayMinutes
        o.stayRadius = stayRadius
        o.movingDistance = movingDistance
        if lowPowerSave && lowBattery {
            o.level = .save
            o.checkMinutes = 0
        }
        return o
    }
}

@MainActor
final class DaySettings: ObservableObject {
    static let shared = DaySettings()
    private static let key = "day.prefs"

    @Published var prefs: DayPrefs {
        didSet {
            guard prefs != oldValue else { return }
            if let d = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(d, forKey: Self.key) }
            onChange?(oldValue)
        }
    }

    /// DayLogger가 설정 바뀔 때 다시 적용
    var onChange: ((DayPrefs) -> Void)?

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let p = try? JSONDecoder().decode(DayPrefs.self, from: d) {
            prefs = p
        } else {
            prefs = DayPrefs()
        }
    }
}
