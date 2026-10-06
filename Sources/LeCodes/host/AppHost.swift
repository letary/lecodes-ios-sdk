// The `app` table (app.d.ts): the app state and connectivity the SDK reads, openUrl, the
// orientation lock, the world-change notification. `exit` stays nil: iOS cannot leave the app
// programmatically, so `quit()` from the boot world is a no-op by contract.
import Foundation
import UIKit
import LeCodesCore

final class AppHost: HostApp {
    weak var engine: LeCodesEngine?

    var state: (() -> String)? { { [weak self] in self?.engine?.appEvents.state ?? "active" } }
    var isOnline: (() -> Bool)? { { [weak self] in self?.engine?.appEvents.online ?? true } }
    var openUrl: ((String) -> Void)? {
        { url in
            guard let parsed = URL(string: url) else { return }
            DispatchQueue.main.async { UIApplication.shared.open(parsed, options: [:], completionHandler: nil) }
        }
    }
    /// "landscape" | "portrait" | "auto" (unknown → auto). The JS thread is the main thread.
    var setOrientation: ((String) -> Void)? { { mode in OrientationLock.apply(OrientationLock(rawValue: mode) ?? .auto) } }
    var worldChange: ((String?, Bool) -> Void)? { { [weak self] uuid, trusted in self?.engine?.onWorldChange(uuid, trusted) } }
}
