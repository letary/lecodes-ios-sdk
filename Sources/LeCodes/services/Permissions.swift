// The OS permissions: ONE service behind `_creatorDevice.queryPermission / requestPermission`
// (the SDK's camera users, `permissions` in an app) and `engine.permissions` for the plugins (the
// generated glue of a method tagged `@permission` asks here before the call; a half whose need
// depends on its arguments — webrtc's getUserMedia — asks by hand, the same way).
//
// The core carries the askers of the camera, the microphone, the location and the notifications
// (alert, sound, badge: what local notifications' `schedule` asks through here). A kind whose
// framework must not be linked into every app (speech: the Speech framework) is REGISTERED by the
// plugin that brings it (`register(.speech, …)`); until then the host says it has no asker.
//
// Requests are queued: two features asking at once get one dialog after the other, one kind asked
// twice while its dialog is up gets one dialog and two answers. iOS asks exactly once — a request
// for a granted or denied kind completes at once with that state (the app's way out is
// `openSettings`).
import AVFoundation
import CoreLocation
import UIKit
import UserNotifications

public enum PermissionKind: String, CaseIterable {
    case camera, microphone, location, speech, notifications
}

public enum PermissionState: String {
    /// Never asked: a request shows the dialog.
    case prompt
    case granted
    /// Refused, or restricted by the device's policy. iOS does not ask again.
    case denied
}

/// What answers for a kind: the state now (any thread), and a request that completes — on any
/// thread, once — with the state after the dialog.
public struct PermissionAsker {
    public let query: () -> PermissionState
    public let request: (@escaping (PermissionState) -> Void) -> Void
    public init(query: @escaping () -> PermissionState, request: @escaping (@escaping (PermissionState) -> Void) -> Void) {
        self.query = query
        self.request = request
    }
}

public final class Permissions {
    private var askers: [PermissionKind: PermissionAsker] = [:]
    private let location = LocationAsker()
    /// The dialog up now and who waits for it, then the kinds behind it.
    private var current: (kind: PermissionKind, waiters: [(PermissionState) -> Void])?
    private var queue: [(kind: PermissionKind, then: (PermissionState) -> Void)] = []

    init() {
        askers[.camera] = Self.capture(.video)
        askers[.microphone] = Self.capture(.audio)
        askers[.location] = PermissionAsker(query: { [location] in location.state }, request: { [location] then in location.request(then) })
        askers[.notifications] = Self.notifications()
    }

    /// The asker of a kind the core does not carry (a plugin's, registered with its halves).
    public func register(_ kind: PermissionKind, _ asker: PermissionAsker) { askers[kind] = asker }

    /// Whether this host can answer for `kind` (its asker is the core's, or a plugin registered one).
    public func knows(_ kind: PermissionKind) -> Bool { askers[kind] != nil }

    /// The state now, no dialog. An unknown kind is `.denied`: nothing on this host can grant it.
    public func query(_ kind: PermissionKind) -> PermissionState { askers[kind]?.query() ?? .denied }

    /// Ask for `kind` and complete with the state after — on the main thread, once. The dialog
    /// shows only for `.prompt`; a granted or denied kind completes at once.
    public func request(_ kind: PermissionKind, _ then: @escaping (PermissionState) -> Void) {
        onMain { [self] in
            let state = query(kind)
            guard state == .prompt, askers[kind] != nil else { return then(state) }
            if let current, current.kind == kind { self.current!.waiters.append(then); return }
            if current != nil { queue.append((kind, then)); return }
            start(kind, then)
        }
    }

    /// Every kind granted (asked one after another, in order), or false at the first that is not.
    public func ensure(_ kinds: [PermissionKind], _ then: @escaping (Bool) -> Void) {
        guard let first = kinds.first else { return onMain { then(true) } }
        request(first) { [self] state in
            guard state == .granted else { return then(false) }
            ensure(Array(kinds.dropFirst()), then)
        }
    }

    /// The app's own page of the system settings: where a denied permission is turned back on.
    public func openSettings() {
        onMain {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }

    // MARK: - the queue (main thread)

    private func start(_ kind: PermissionKind, _ then: @escaping (PermissionState) -> Void) {
        current = (kind, [then])
        askers[kind]!.request { [weak self] state in
            self?.onMain { self?.finish(state) }
        }
    }

    private func finish(_ state: PermissionState) {
        guard let done = current else { return }
        current = nil
        for waiter in done.waiters { waiter(state) }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        request(next.kind, next.then)   // re-checked: the dialog just answered may have covered it
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    // MARK: - the core's askers

    private static func capture(_ media: AVMediaType) -> PermissionAsker {
        PermissionAsker(
            query: {
                switch AVCaptureDevice.authorizationStatus(for: media) {
                case .authorized: return .granted
                case .notDetermined: return .prompt
                default: return .denied
                }
            },
            request: { then in AVCaptureDevice.requestAccess(for: media) { then($0 ? .granted : .denied) } }
        )
    }

    /// Notifications: the center's authorization status. The center answers in a completion on its
    /// own queue while `query` answers now, so the read waits for it — never on that queue, so waiting
    /// on the main thread is safe — capped: an unanswered read is `.prompt`, and a request then asks
    /// the center, which answers at once for a decided status. The center is touched only when asked
    /// (it raises in a process without an app bundle, and the package's tests build every asker).
    private static func notifications() -> PermissionAsker {
        PermissionAsker(
            query: {
                let read = SettingsRead()
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    read.status = settings.authorizationStatus
                    read.done.signal()
                }
                guard read.done.wait(timeout: .now() + 2) == .success, let status = read.status else { return .prompt }
                return Permissions.state(status)
            },
            request: { then in
                let center = UNUserNotificationCenter.current()
                center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                    center.getNotificationSettings { then(Permissions.state($0.authorizationStatus)) }
                }
            }
        )
    }

    private static func state(_ status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined: return .prompt
        default: return .denied
        }
    }
}

/// One read of the notification settings across the center's queue: `status` is written there
/// before `done` signals.
private final class SettingsRead {
    let done = DispatchSemaphore(value: 0)
    var status: UNAuthorizationStatus?
}

/// Location (while in use): CLLocationManager's status, its dialog answered through the delegate.
private final class LocationAsker: NSObject, CLLocationManagerDelegate {
    private lazy var manager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        return m
    }()
    private var pending: ((PermissionState) -> Void)?

    var state: PermissionState {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return .granted
        case .notDetermined: return .prompt
        default: return .denied
        }
    }

    func request(_ then: @escaping (PermissionState) -> Void) {
        pending = then
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Fires once at the manager's creation too (still undetermined): not an answer.
        let now = state
        guard now != .prompt, let then = pending else { return }
        pending = nil
        then(now)
    }
}
