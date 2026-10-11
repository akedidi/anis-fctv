import Foundation

/// Deterministic data used **only** when `UITestingConfiguration.isEventFlowUITest` is true.
/// Keeps `XCUITest` stable without hitting the network.
enum MatchServiceUITestSeed {
    private static let demoHLS = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!

    static let matches: [LiveMatch] = {
        let now = Date()
        let s1 = StreamServer(
            name: "beIN Sports FR",
            fullName: "beIN Sports 1",
            playbackURL: demoHLS,
            resolution: "HD",
            language: "FR",
            country: "France",
            countryCode: "FR",
            backendStreamId: 1,
            backendSiteType: 1
        )
        return [
            LiveMatch(
                id: "1",
                sport: .football,
                leagueName: "UEFA Champions League",
                leagueLogoURL: nil,
                leagueFlag: "🇪🇺",
                region: "Europe",
                contenders: [
                    Contender(name: "Real Madrid", flag: "🇪🇸"),
                    Contender(name: "Manchester City", flag: "🏴󠁧󠁢󠁥󠁮󠁧󠁿"),
                ],
                homeScore: 2,
                awayScore: 1,
                status: .secondHalf,
                startDate: now.addingTimeInterval(-3600),
                liveClock: "67'",
                hot: true,
                streams: [s1]
            ),
            LiveMatch(
                id: "2164101",
                sport: .volleyball,
                leagueName: "AVC Champions League",
                leagueLogoURL: nil,
                leagueFlag: "🏐",
                region: "Asia",
                contenders: [
                    Contender(name: "JTEKT Stings", flag: "🇯🇵"),
                    Contender(name: "Nakhon Ratchasima", flag: "🇹🇭"),
                ],
                homeScore: 2,
                awayScore: 1,
                status: .secondHalf,
                startDate: now.addingTimeInterval(-1200),
                liveClock: "Set 4",
                hot: true,
                streams: [
                    StreamServer(
                        name: "AVC 1",
                        fullName: "",
                        playbackURL: demoHLS,
                        resolution: "FHD",
                        language: "FR",
                        country: "Japan",
                        countryCode: "JP",
                        backendStreamId: 2,
                        backendSiteType: 1
                    ),
                ]
            ),
        ]
    }()

    static var previewMatch: LiveMatch { matches[0] }
}
