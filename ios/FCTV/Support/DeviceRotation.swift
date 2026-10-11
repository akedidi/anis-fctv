import UIKit

/// App delegate hook for forced orientation (streamsports pattern).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

/// Forces interface orientation (streamsports `DeviceRotation`).
enum DeviceRotation {
    static func rotate(to orientation: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = orientation
        if #available(iOS 16.0, *) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            UIViewController.attemptRotationToDeviceOrientation()
        } else {
            let value: UIInterfaceOrientation =
                orientation.contains(.landscapeRight) ? .landscapeRight : .portrait
            UIDevice.current.setValue(value.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
        fputs("[rotate] lock=\(orientation.rawValue)\n", stderr)
    }
}
