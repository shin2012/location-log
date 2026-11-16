import XCTest

final class LevelPickerTests: XCTestCase {
    func testScrollReleaseThenSelectBasement() {
        let app = XCUIApplication()
        app.launchArguments = ["-floorLayoutShot", "YES", "-AppleLanguages", "(ko)"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1F 추정")).firstMatch.tap()
        let picker = app.collectionViews["level-picker-list"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "층 선택은 독립적인 스크롤 목록이어야 한다")
        let target = app.buttons["level-option--6"]
        for _ in 0..<8 {
            if target.exists && target.isHittable { break }
            picker.swipeUp()
        }
        XCTAssertTrue(target.isHittable, "손을 뗀 뒤에도 스크롤한 층을 누를 수 있어야 한다")
        // 감속이 끝난 뒤에도 목록이 처음으로 돌아가지 않아야 한다.
        let before = target.frame
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(target.isHittable)
        XCTAssertEqual(target.frame.minY, before.minY, accuracy: 3)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "층 목록 스크롤 후 손 뗌"
        shot.lifetime = .keepAlways
        add(shot)
        target.tap()
        XCTAssertTrue(app.staticTexts["선택 결과: B6"].waitForExistence(timeout: 5))
        XCTAssertFalse(picker.exists)
    }
}
