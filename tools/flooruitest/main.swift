import Foundation

// TimelineModels.swift의 실제 층 모델을 사용한다. 리눅스에서는 CoreLocation만 임시 모듈로 대체한다.
func floor(_ via: String?, level: Int = 1) -> TimelineFloor {
    TimelineFloor(start: 0, end: 60_000, level: level, label: level < 0 ? "B\(-level)" : "\(level + 1)F",
                  est: true, via: via, dh: 0, ap: nil, subs: nil)
}

assert(floor("stairs").viaLabel == "계단으로 2층에 도착")
assert(floor("elevator", level: -2).viaLabel == "엘리베이터로 지하 2층에 도착")
assert(floor("escalator", level: 0).viaLabel == "에스컬레이터로 1층에 도착")
assert(floor(nil).viaLabel == nil)
assert(floor("unknown").viaLabel == nil)
print("층 도착 설명: 통과")

assert(floor("stairs").viaSymbol == "figure.stairs")
assert(floor("elevator").viaSymbol == "arrow.up.arrow.down.square")
assert(floor("escalator").viaSymbol == "arrow.up.forward")
assert(floor(nil).viaSymbol == nil)
assert(floor("unknown").viaSymbol == nil)
print("이동 설명 아이콘: 통과")

assert(floor(nil).durationLabel == "1분")
let longStay = TimelineFloor(start: 0, end: 5_520_000, level: 1, label: "2F", est: true, via: nil, dh: 0, ap: nil, subs: nil)
assert(longStay.durationLabel == "92분")
let zeroStay = TimelineFloor(start: 0, end: 0, level: 1, label: "2F", est: true, via: nil, dh: 0, ap: nil, subs: nil)
assert(zeroStay.durationLabel == "시간 미확인")
print("괄호 안 분 단위 길이: 통과")
