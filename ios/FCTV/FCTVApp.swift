import AVFoundation
import SwiftUI

@main
struct FCTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var playbackSession = PlaybackSession()

    init() {
        // Background audio + PiP (streamsports AppDelegate pattern).
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            fputs("[audio] session setup failed: \(error.localizedDescription)\n", stderr)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(playbackSession)
        }
    }
}
