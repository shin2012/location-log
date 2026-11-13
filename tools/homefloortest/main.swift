// swiftc -O ios/LocationLog/ParkModel.swift ios/LocationLog/TimelineCalc.swift tools/homefloortest/main.swift -o <scratch>/homefloortest
// tests/test_home_floors.py --fixtures <scratch>/homefloors.json 로 만든 중립 자료를 사용.
import Foundation
struct Case: Decodable {
    var name: String
    var input: CalcInput
    var expected: CalcDayExpect
}
struct CalcDayExpect: Decodable { var levels: [Int]; var elevator: Bool }
let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try dec.decode([Case].self, from: data)
var failed = 0
for c in cases {
    let result = TimelineCalc.build(c.input, date: "2026-11-13")
    let fs = result.items.first { $0.kind == "visit" }?.floors ?? []
    let actual = fs.map(\.level)
    let ok = actual == c.expected.levels && (!c.expected.elevator || fs.last?.via == "elevator") && fs.allSatisfy { $0.end > $0.start }
    print(ok ? "ok" : "FAIL", c.name, actual, fs.map { $0.via ?? "start" })
    if !ok { failed += 1 }
}
exit(failed == 0 ? 0 : 1)
