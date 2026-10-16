import XCTest

final class HHVacancyCBRUITestsLaunchTests: XCTestCase {
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HHVACANCYCBR_UI_TEST_MODE"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "ЦБВакансии"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
