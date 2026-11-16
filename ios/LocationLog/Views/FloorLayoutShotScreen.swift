#if DEBUG
import SwiftUI

/// 서버·개인 기록 없이 실제 FloorRow/LevelMenu를 List 안에서 렌더링한다.
struct FloorLayoutShotScreen: View {
    @State private var heights: [String: CGFloat] = [:]
    @State private var selectedLevel: String?
    private let floors: [TimelineFloor] = {
        let start = 1_800_000_000_000.0
        return [
            TimelineFloor(start: start, end: start, level: 0, label: "1F", est: true, via: nil, dh: 0, ap: nil, subs: nil),
            TimelineFloor(start: start + 60_000, end: start + 1_560_000, level: 1, label: "2F", est: true, via: "stairs", dh: 4.5, ap: nil, subs: nil),
            TimelineFloor(start: start + 1_620_000, end: start + 8_820_000, level: -2, label: "B2", est: false, via: "elevator", dh: -7, ap: nil, subs: nil),
            TimelineFloor(start: start + 8_880_000, end: start + 8_940_000, level: 0, label: "1F", est: true, via: "escalator", dh: 0, ap: nil, subs: nil)
        ]
    }()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("머문 곳", systemImage: "mappin.circle.fill").font(.headline)
                    ForEach(floors) { floor in
                        FloorRow(floor: floor) { lv in selectedLevel = lv.map(ParkModel.label) ?? "추정" }
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: FloorHeights.self, value: [String(floor.start): proxy.size.height])
                            })
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("층 기록 화면 확인")
            .safeAreaInset(edge: .bottom) {
                if let selectedLevel { Text("선택 결과: " + selectedLevel) }
            }
            .onPreferenceChange(FloorHeights.self) { values in
                heights = values
                guard values.count == floors.count else { return }
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("floor-layout.json")
                if let data = try? JSONEncoder().encode(values) { try? data.write(to: url, options: .atomic) }
            }
        }
        .dynamicTypeSize(UserDefaults.standard.bool(forKey: "floorShotLarge") ? .accessibility1 : .large)
    }
}

private struct FloorHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
#endif
