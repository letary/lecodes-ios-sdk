// device.motion (device.d.ts): Core Motion fuses continuously at the hardware rate, the render loop
// pulls the freshest sample — `[qx,qy,qz,qw, gx,gy,gz, interfaceOrientation]` in the DEVICE frame
// (the SDK converts it). The orientation code is cached on the main thread (the sample may be read
// off-main); a one-frame stale code right after a rotation is harmless.
import Foundation
import CoreMotion
import UIKit

final class Motion {
    private let manager = CMMotionManager()
    private var orientationCode = 0
    private var orientationObserver: NSObjectProtocol?

    var available: Bool { manager.isDeviceMotionAvailable }

    func start(interval: Double) -> Bool {
        guard manager.isDeviceMotionAvailable else { return false }
        manager.deviceMotionUpdateInterval = interval > 0 ? interval : 1.0 / 60.0
        if !manager.isDeviceMotionActive { manager.startDeviceMotionUpdates() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshOrientation()
            if self.orientationObserver == nil {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                self.orientationObserver = NotificationCenter.default.addObserver(
                    forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in self?.refreshOrientation() }
            }
        }
        return true
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        DispatchQueue.main.async { [weak self] in
            guard let self, let obs = self.orientationObserver else { return }
            NotificationCenter.default.removeObserver(obs)
            self.orientationObserver = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
    }

    /// nil until the first sample / when not running.
    func sample() -> [Float]? {
        guard let dm = manager.deviceMotion else { return nil }
        let q = dm.attitude.quaternion
        let g = dm.gravity
        return [Float(q.x), Float(q.y), Float(q.z), Float(q.w), Float(g.x), Float(g.y), Float(g.z), Float(orientationCode)]
    }

    private func refreshOrientation() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        switch scene.interfaceOrientation {
        case .portrait: orientationCode = 0
        case .landscapeLeft: orientationCode = 1
        case .landscapeRight: orientationCode = 2
        case .portraitUpsideDown: orientationCode = 3
        default: break
        }
    }
}
