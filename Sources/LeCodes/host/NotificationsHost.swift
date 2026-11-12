// The `notifications` table (notifications.d.ts): local notifications over the engine's
// LocalNotifications (services/LocalNotifications.swift — the schedule, the world's namespace, the
// taps). Thin: the request parsed, the permission asked through the engine's one door
// (services/Permissions.swift, the "notifications" kind — `schedule` is the moment the user expects
// the dialog: a never-asked kind shows it, a refused one rejects "denied"), the world read at the
// call — the JS thread is the main thread, so it is the calling world's, kept through the dialog —
// and every answer settled on the main thread.
import Foundation
import LeCodesCore

final class NotificationsHost: HostNotifications {
    weak var engine: LeCodesEngine?

    func schedule(request: String, onComplete: JSCallback, onReject: JSCallback) {
        guard let engine else { return Core.reject(onComplete, reject: onReject, message: "unavailable") }
        let parsed: LocalNotifications.Request
        switch LocalNotifications.Request.parse(request) {
        case .success(let value): parsed = value
        case .failure(let rejection): return Core.reject(onComplete, reject: onReject, message: rejection.message)
        }
        let world = engine.currentProjectUuid
        let local = engine.localNotifications
        engine.permissions.request(.notifications) { state in
            guard state == .granted else {
                return Core.reject(onComplete, reject: onReject, message: state == .denied ? "denied" : "unavailable")
            }
            local.schedule(parsed, world: world) { failure in
                if let failure { Core.reject(onComplete, reject: onReject, message: failure) }
                else { Core.resolve(onComplete, reject: onReject, [.string(parsed.id)]) }
            }
        }
    }

    func cancel(id: String) {
        guard let engine else { return }
        engine.localNotifications.cancel(id, world: engine.currentProjectUuid)
    }

    func cancelAll() {
        guard let engine else { return }
        engine.localNotifications.cancelAll(world: engine.currentProjectUuid)
    }

    func pending(onComplete: JSCallback, onReject: JSCallback) {
        guard let engine else { return Core.resolve(onComplete, reject: onReject, [.string("[]")]) }
        engine.localNotifications.pending(world: engine.currentProjectUuid) { json in
            Core.resolve(onComplete, reject: onReject, [.string(json)])
        }
    }

    func launchTap() -> String? {
        guard let engine else { return nil }
        return engine.localNotifications.launchTap(world: engine.currentProjectUuid)
    }
}
