// swift-tools-version: 5.10
// Single-module executable: same sources as the iOS app backend slice (no `public` exports needed).
import PackageDescription

let package = Package(
    name: "PlaybackProbe",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "playback-probe", targets: ["playback_probe"]),
    ],
    targets: [
        .executableTarget(
            name: "playback_probe",
            path: "Sources/playback_probe",
            exclude: [
                "Models/HomeFilter.swift",
            ],
            sources: [
                "PlaybackProbeEntry.swift",
                "PlaybackProbeEnv.swift",
                "PlaybackProbeMacPlayback.swift",
                "Models/AppLanguage.swift",
                "Models/Match.swift",
                "Models/MatchHighlight.swift",
                "Models/MatchStatus.swift",
                "Models/Sport.swift",
                "Support/CountryHelper.swift",
                "Rblive/RbliveGeoParameters.swift",
                "Rblive/RbliveHTTPClient.swift",
                "Rblive/RbliveHlsAssetLoader.swift",
                "Rblive/RbliveHlsInjectEngine.swift",
                "Rblive/RbliveHlsProxyURL.swift",
                "Rblive/RbliveCslResolver.swift",
                "Rblive/RbliveLocalHlsServer.swift",
                "Rblive/RbliveMatchRepository.swift",
                "Rblive/RbliveProtobuf.swift",
                "Rblive/RbliveSportLanguage.swift",
                "Rblive/RbliveStreamCrypto.swift",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ], .when(platforms: [.macOS])),
            ]
        ),
    ]
)
