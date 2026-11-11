// 앱 TimelineCalc ↔ 서버 timeline.py 대조 (실제 날짜 tests/data/calc/*.json: inputs + expected)
// swiftc -O ios/LocationLog/ParkModel.swift ios/LocationLog/TimelineCalc.swift tools/calctest/main.swift -o /tmp/ct && /tmp/ct tests/data/calc
import Foundation

struct Fixture: Decodable { let date: String; let inputs: CalcInput }

func norm(_ x: Any) -> Any {
    if let d = x as? [String: Any] {
        var o: [String: Any] = [:]
        for (k, v) in d where !(v is NSNull) { o[k] = norm(v) }
        return o
    }
    if let a = x as? [Any] { return a.map(norm) }
    return x
}

var diffs: [String] = []
func cmp(_ a: Any, _ b: Any, _ path: String) {
    if let x = a as? [String: Any], let y = b as? [String: Any] {
        for k in Set(x.keys).union(y.keys) {
            guard let xa = x[k], let yb = y[k] else { diffs.append("\(path).\(k): \(x[k] == nil ? "없음" : "\(x[k]!)") ≠ \(y[k] == nil ? "없음" : "\(y[k]!)")"); continue }
            cmp(xa, yb, path + "." + k)
        }
    } else if let x = a as? [Any], let y = b as? [Any] {
        if x.count != y.count { diffs.append("\(path): 개수 \(x.count) ≠ \(y.count)"); return }
        for i in x.indices { cmp(x[i], y[i], "\(path)[\(i)]") }
    } else if let x = a as? NSNumber, let y = b as? NSNumber {
        let dx = x.doubleValue, dy = y.doubleValue
        if abs(dx - dy) > max(1e-6, abs(dy) > 1e11 ? 1.5 : 1e-6) { diffs.append("\(path): \(dx) ≠ \(dy)") }
    } else if "\(a)" != "\(b)" {
        diffs.append("\(path): \(a) ≠ \(b)")
    }
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tests/data/calc"
let files = try! FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }.sorted()
let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
let enc = JSONEncoder()
var bad = 0
for f in files {
    let data = try! Data(contentsOf: URL(fileURLWithPath: dir + "/" + f))
    let fx = try! dec.decode(Fixture.self, from: data)
    let exp = (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["expected"]!
    let t0 = Date()
    let got = TimelineCalc.build(fx.inputs, date: fx.date)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    let gj = try! JSONSerialization.jsonObject(with: try! enc.encode(got))
    diffs = []
    cmp(norm(gj), norm(exp), "")
    print(diffs.isEmpty ? "ok  " : "FAIL", fx.date, "항목 \(got.items.count)", "\(ms)ms")
    for d in diffs.prefix(12) { print("     ", d) }
    if !diffs.isEmpty { bad += 1 }
}
exit(bad == 0 ? 0 : 1)
