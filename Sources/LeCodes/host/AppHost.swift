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
    // app.host.version / app.host.build — the installed app's CFBundleShortVersionString /
    // CFBundleVersion (what a `lecodes app` shell takes from app.json). An OTA bundle reads them to
    // branch on the native side; a non-numeric CFBundleVersion reads as 0.
    var appVersion: (() -> String)? { { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" } }
    var appBuild: (() -> Int32)? { { Int32((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) } ?? 0) } }
    // app.update — the source a SHELL's updater takes newer bundles from (LeCodesUpdater). Any other
    // app of this SDK (the viewer, a library host) never boots through the updater: no override is
    // read there, so none is reported or stored.
    var updateSource: (() -> String)? { { LeCodesUpdater.isShell ? (LeCodesUpdater.sourceOverride?.absoluteString ?? "") : "" } }
    var setUpdateSource: ((String) -> Bool)? {
        { url in
            guard LeCodesUpdater.isShell else { return false }
            if url.isEmpty { return LeCodesUpdater.setSourceOverride(nil) }
            guard let parsed = URL(string: url) else { return false }
            return LeCodesUpdater.setSourceOverride(parsed)
        }
    }
    // app.splash — the launch screen a SHELL's boot holds (SplashHold of LeCodesShell); no such
    // launch in any other app of this SDK, so nothing is held there.
    var holdSplash: (() -> Bool)? { { LeCodesShell.splash?.hold() ?? false } }
    var hideSplash: (() -> Void)? { { LeCodesShell.splash?.hide() } }
}
