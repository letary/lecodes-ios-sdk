// The interface-orientation lock (app.setOrientation): host-global — the view controller reads
// `current` from supportedInterfaceOrientations. PER WORLD: HostApp.worldChange releases it before
// the new bundle evaluates, so a game may lock at synchronous top level and the launcher always
// comes back to `.auto`.
import Foundation
import UIKit

public enum OrientationLock: String {
    case auto, portrait, landscape

    public private(set) static var current: OrientationLock = .auto

    /// The mask a lock imposes; nil for .auto (UIKit's default, the Info.plist list).
    public var mask: UIInterfaceOrientationMask? {
        switch self {
        case .landscape: return .landscape
        case .portrait: return .portrait
        case .auto: return nil
        }
    }

    /// Main thread. Store the lock and ask UIKit to rotate NOW rather than on the next physical
    /// turn (iOS 16+: the supported-orientations invalidation + a geometry request).
    public static func apply(_ lock: OrientationLock) {
        current = lock
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?.rootViewController
        if #available(iOS 16.0, *) {
            root?.setNeedsUpdateOfSupportedInterfaceOrientations()
            guard let mask = lock.mask else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                print("[app] setOrientation(\(lock.rawValue)) failed: \(error.localizedDescription)")
            }
        } else {
            switch lock {
            case .landscape:
                let target: UIInterfaceOrientation = scene.interfaceOrientation.isLandscape ? scene.interfaceOrientation : .landscapeRight
                UIDevice.current.setValue(target.rawValue, forKey: "orientation")
            case .portrait:
                UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            case .auto:
                break
            }
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
