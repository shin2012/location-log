import AppIntents

/// 단축어 자동화의 'CarPlay 연결 시 / 연결 해제 시' 트리거(애플 공식 신호)에서 시야쥬를 부르는 동작.
/// 단축어: 자동화 › CarPlay › 연결 시 › 동작 '시야쥬 › CarPlay 연결 기록하기' (해제 시도 같은 방법으로 'CarPlay 연결 해제 기록하기').
/// 앱이 꺼져 있으면 iOS가 백그라운드로 켜서 실행 → 서버 전송·운전 1초 기록이 앱 안에서 같이 처리됨.
struct CarPlayConnectedIntent: AppIntent {
    static var title: LocalizedStringResource = "CarPlay 연결 기록하기"
    static var description = IntentDescription("단축어 자동화 'CarPlay 연결 시'에 넣으세요. 운전 시작을 기록하고 서버로 보냅니다.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        CarPlayWatcher.shared.set(true)
        await CarPlayEvents.shared.flush()
        return .result()
    }
}

struct CarPlayDisconnectedIntent: AppIntent {
    static var title: LocalizedStringResource = "CarPlay 연결 해제 기록하기"
    static var description = IntentDescription("단축어 자동화 'CarPlay 연결 해제 시'에 넣으세요. 운전 끝을 기록하고 서버로 보냅니다.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        CarPlayWatcher.shared.set(false)
        await CarPlayEvents.shared.flush()
        return .result()
    }
}

struct SillageShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CarPlayConnectedIntent(), phrases: ["\(.applicationName) CarPlay 연결 기록하기"],
                    shortTitle: "CarPlay 연결 기록하기", systemImageName: "car.fill")
        AppShortcut(intent: CarPlayDisconnectedIntent(), phrases: ["\(.applicationName) CarPlay 연결 해제 기록하기"],
                    shortTitle: "CarPlay 연결 해제 기록하기", systemImageName: "car")
    }
}
