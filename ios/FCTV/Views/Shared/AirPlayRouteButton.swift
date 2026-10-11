import AVKit
import SwiftUI
import UIKit

/// System AirPlay route picker (`AVRoutePickerView`) — replaces Chromecast UI.
struct AirPlayRouteButton: UIViewRepresentable {
    var tintColor: UIColor = .white
    var prioritizesVideoDevices: Bool = true

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tintColor
        view.activeTintColor = UIColor(red: 1, green: 0.682, blue: 0.004, alpha: 1) // Theme accent
        view.prioritizesVideoDevices = prioritizesVideoDevices
        // Transparent so it sits inside our capsule / circle chrome.
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = UIColor(red: 1, green: 0.682, blue: 0.004, alpha: 1)
        uiView.prioritizesVideoDevices = prioritizesVideoDevices
    }
}
