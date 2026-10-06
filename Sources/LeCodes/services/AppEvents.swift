// The app-lifecycle channel (app.d.ts): "pause" / "resume" from the UIApplication notifications —
// "pause" means the app truly left the foreground (didEnterBackground, not the transient inactive
// state), "resume" only closes a real background round-trip — and "online" / "offline" from
// NWPathMonitor (the first update seeds silently: the events fire on CHANGES, like navigator.onLine).
// "pause" is delivered INSIDE the notification with one explicit tick, before the frame loop stops:
// after the display link is gone nothing pumps the JS world.
import Foundation
import Network
import UIKit
import LeCodesCore

final class AppEvents {
    weak var engine: LeCodesEngine?

    /// "active" | "background" — HostApp.state.
    private(set) var state = "active"
    private(set) var online = true
    private var pathKnown = false
    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.pathKnown {
                    self.pathKnown = true
                    self.online = satisfied
                } else if self.online != satisfied {
                    self.online = satisfied
                    Core.emitAppEvent(satisfied ? "online" : "offline")
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "codes.le.lecodes.network-path"))

        let center = NotificationCenter.default
        // queue: nil runs the block synchronously on the posting thread (UIKit posts on main).
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.moveToBackground()
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.returnToForeground()
        })
    }

    func stop() {
        pathMonitor.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    func moveToBackground() {
        guard state != "background" else { return }
        state = "background"
        Core.emitAppEvent("pause")
        engine?.tick()       // the app hears "pause" now, while the queue still drains
        engine?.pause()
    }

    func returnToForeground() {
        guard state == "background" else { return }
        state = "active"
        engine?.resume()
        Core.emitAppEvent("resume")
    }
}
