import XCTest

/// End-to-end UI test for the **event** (match) user journey:
/// home list → open match (player) → interact with stream / detail tabs → return home.
///
/// The app is launched with `--uitesting-event-flow` so `AppState` starts on **Home**
/// with mock matches (deterministic, no network activation). This mirrors the real
/// flow after a user is activated while keeping CI stable.
final class EventFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--uitesting-event-flow")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testEventFlow_openMatch_selectServer_switchStatsTab_closePlayer() throws {
        app.launch()

        let home = app.descendants(matching: .any).matching(byId("home.root")).element
        XCTAssertTrue(home.waitForExistence(timeout: 25), "Home screen should appear (UI test launch argument).")

        let firstRow = app.descendants(matching: .any).matching(byId("home.matchRow.first")).element
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "At least one match row should be visible.")
        firstRow.tap()

        let playerRoot = app.descendants(matching: .any).matching(byId("player.root")).element
        XCTAssertTrue(playerRoot.waitForExistence(timeout: 20), "Player (match detail) should open.")

        let serversSection = app.descendants(matching: .any).matching(byId("player.servers.section")).element
        if serversSection.waitForExistence(timeout: 10) {
            let firstServer = app.descendants(matching: .any).matching(byId("player.server.first")).element
            if firstServer.waitForExistence(timeout: 8) {
                firstServer.tap()
            }
        }

        let statsTab = app.descendants(matching: .any).matching(byId("player.tab.stats")).element
        XCTAssertTrue(statsTab.waitForExistence(timeout: 12), "Stats tab should be visible.")
        statsTab.tap()

        let statsHeading = app.descendants(matching: .any).matching(byId("player.stats.heading")).element
        if !statsHeading.waitForExistence(timeout: 4) {
            app.swipeUp()
        }
        XCTAssertTrue(statsHeading.waitForExistence(timeout: 12), "Stats content should load after selecting the tab.")

        // Close lives in the top overlay (sibling of the scroll area), not under `player.root`, so query the app.
        let close = app.descendants(matching: .any).matching(byId("player.close")).element
        XCTAssertTrue(close.waitForExistence(timeout: 15), "Close control should be visible on the player screen.")
        close.tap()

        XCTAssertTrue(home.waitForExistence(timeout: 12), "Should return to home after closing the player.")
    }

    private func byId(_ value: String) -> NSPredicate {
        NSPredicate(format: "identifier == %@", value)
    }
}
