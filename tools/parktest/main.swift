// swiftc ios/LocationLog/ParkModel.swift tools/parktest/main.swift -o /tmp/pt && /tmp/pt  — server/parking.py 와 같은 결과인지
import Foundation
func c(_ dh: Double, _ lv: Int, _ la: Double = 37.5, _ lo: Double = 127.0) -> ParkCal { ParkCal(lat: la, lon: lo, dh: dh, level: lv) }
func check(_ ok: Bool, _ m: String) { print(ok ? "ok" : "FAIL", m); if !ok { exit(1) } }
check(ParkModel.label(-3) == "B3" && ParkModel.label(0) == "1F" && ParkModel.label(2) == "3F", "label")
check(abs(ParkModel.dh(refKpa: 101.325, nowKpa: 101.225) - 8.33) < 0.05, "dh")
check(ParkModel.estimate(dh: -9.8, lat: 37.5, lon: 127, cal: []) == -3, "default B3")
check(ParkModel.estimate(dh: -1.0, lat: 37.5, lon: 127, cal: []) == 0, "default 1F")
check(ParkModel.estimate(dh: 6.5, lat: 37.5, lon: 127, cal: []) == 2, "default 3F")
let one = [c(-9.8, -2)]
check(ParkModel.estimate(dh: -9.9, lat: 37.5, lon: 127, cal: one) == -2, "one corr")
check(ParkModel.estimate(dh: -14.5, lat: 37.5, lon: 127, cal: one) == -3, "one corr B3")
let far = ParkModel.model(lat: 37.6, lon: 127.1, cal: one); check(far.a == 4.9 && far.b == 0, "far global")
let two = [c(-5.5, -1), c(-9.0, -2)]; let m2 = ParkModel.model(lat: 37.5, lon: 127, cal: two)
check(abs(m2.a - 3.5) < 1e-9 && abs(m2.b + 2) < 1e-9, "fit"); check(ParkModel.estimate(dh: -12.4, lat: 37.5, lon: 127, cal: two) == -3, "fit B3")
let g = ParkModel.model(lat: 37.5, lon: 127, cal: [c(1.5, 0)]); check(g.a == 3.2 && abs(g.b - 1.5) < 1e-9, "ground")
let bad = ParkModel.model(lat: 37.5, lon: 127, cal: [c(-1.0, -1)]); check(bad.a == 3.2 && abs(bad.b - 2.2) < 1e-9, "bad")
check(ParkModel.estimate(dh: -1.2, lat: 37.5, lon: 127, cal: [c(-1.0, -1)]) == -1, "bad B1")
