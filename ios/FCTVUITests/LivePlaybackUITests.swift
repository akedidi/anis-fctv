import XCTest

/// Real-network UI test: resolves a public event URL (same numeric id as web slugs), opens the player,
/// starts playback, and waits until the app reports `playing` (HLS + optional `_sou` via `RbliveHlsAssetLoader`).
///
/// Run: `./scripts/run-live-playback-ui-test.sh` or pass a custom URL as first argument.
final class LivePlaybackUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Default: MadPlay77-style sample URL (match id `4401195` in league slug).
    func testLivePlayback_resolvesEventURLAndStartsStream() throws {
        let urlString = ProcessInfo.processInfo.environment["FCTV_LIVE_PLAYBACK_URL"]
            ?? "https://jack01eo.mp7786j2ncsusov57general.ru/fr/football/pro-futsal-league-2-4401195/kln-elite-fc-vs-maestro.html?icg=RlI&ilang=fr"
        app.launchArguments = [
            "--uitesting-live-playback",
            "--uitesting-playback-url",
            urlString.trimmingCharacters(in: .whitespacesAndNewlines),
            "--uitesting-stinj-enabled",
        ]
        app.launch()

        let player = app.descendants(matching: .any).matching(identifier: "player.root").element
        XCTAssertTrue(player.waitForExistence(timeout: 120), "Player should open after `/api/match/detail` for the slug URL.")

        let playBtn = app.descendants(matching: .any).matching(identifier: "player.playButton").element
        XCTAssertTrue(playBtn.waitForExistence(timeout: 30), "Play control should be visible for a match with streams.")
        playBtn.tap()

        let state = app.descendants(matching: .any).matching(identifier: "player.uiTest.playbackState").element
        XCTAssertTrue(state.waitForExistence(timeout: 15), "Playback state probe should exist.")

        let deadline = Date().addingTimeInterval(150)
        var didPlay = false
        while Date() < deadline {
            if (state.value as? String) == "playing" {
                didPlay = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        XCTAssertTrue(didPlay, "Expected AVPlayer timeControlStatus playing within timeout (HLS + rblivehls proxy).")
    }
}
