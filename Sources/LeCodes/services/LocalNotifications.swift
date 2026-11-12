// Local notifications over UNUserNotificationCenter: the service behind the `notifications` table
// (host/NotificationsHost.swift, sdk/src/bridges/notifications.d.ts) and the core's half of the
// notification-center delegate — services/AppHooks.swift hands the taps on THESE notifications here
// (recognised by their userInfo key, `key`) and everything else to the push plugin, as before.
//
// WORLD ATTRIBUTION. A notification belongs to the project of the world that scheduled it: its
// request identifier is "<projectUuid>|<id>" ("|<id>" for an unattributed world), so an id, cancel,
// cancelAll and pending are scoped to the world by that prefix, and two projects' "daily" never
// collide. The content's userInfo carries what a tap needs: ["lecodes.local": { projectUuid?,
// payload, repeat? }] — `payload` the NotificationTap as JSON TEXT: the app's `data` is arbitrary
// JSON, and a null inside it is not a property-list value the center would store.
//
// THE SCHEDULE is the center's: it survives the process, iOS fires it with the app closed. `at`
// absent or not in the future: no trigger, shown now. One-shot: a calendar trigger on `at`'s date and
// wall-clock second. Repeating: a calendar trigger on `at`'s time of day (daily) or weekday + time of
// day (weekly). iOS fires such a trigger at the NEXT matching wall-clock time — it has no start date —
// so the first fire is the next occurrence of `at`'s time from now: an `at` in the past repeats from
// its next occurrence (it is not shown now), one more than a period ahead starts early. Scheduling an
// id again replaces it: the pending request and the shown notification of that identifier go first.
//
// A TAP follows the push plugin's rules (PushManager.swift). This world's notification → the
// "notification" app event, the tap's JSON as its data; another project's → parked, and the launcher
// re-entered with https://le.codes/qr/<uuid> — that project's world reads it with `launchTap()`; an
// unattributed world's notification while an attributed world runs → the tap only opened the app.
// The tap that COLD-STARTED the app (connectionOptions.notificationResponse) → parked, the launch URL
// seeded to its project before the JS world boots, and its identifier remembered: iOS reports that
// tap again as didReceive while the launcher is still fetching the project, and acting on it would
// re-enter the launcher and build the world twice. A parked tap is served only to a world of its own
// project (both unattributed counts), the same one on every call, until another tap replaces it.
//
// The center is touched only when called: UNUserNotificationCenter.current() raises in a process
// without an app bundle (the package's tests), and every engine carries this service.
// Main-thread confined; the center's completions hop back before touching state or answering.
import Foundation
import LeCodesCore
import UserNotifications

final class LocalNotifications {
    weak var engine: LeCodesEngine?

    /// The userInfo key of a local notification — what the delegate routes by.
    static let key = "lecodes.local"

    enum Repeat: String { case daily, weekly }

    /// A malformed request's reject message.
    struct Rejection: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// A NotificationRequest, parsed: the trigger's inputs and the tap's JSON, built once here.
    struct Request {
        let id: String
        let title: String
        let body: String?
        /// Unix ms.
        let at: Double?
        let repeating: Repeat?
        /// The NotificationTap's JSON: { id, title, body?, url?, data? }.
        let tap: String

        /// The wire JSON of a NotificationRequest; an absent id is generated.
        static func parse(_ json: String) -> Result<Request, Rejection> {
            guard let object = LocalNotifications.object(json) else {
                return .failure(Rejection("notifications.schedule: the request is not a JSON object"))
            }
            guard let title = object["title"] as? String else {
                return .failure(Rejection("notifications.schedule: a title is required"))
            }
            let id = object["id"] as? String ?? UUID().uuidString
            let body = object["body"] as? String
            let at = (object["at"] as? NSNumber)?.doubleValue
            var repeating: Repeat? = nil
            if let wire = object["repeat"] {
                guard let name = wire as? String, let kind = Repeat(rawValue: name) else {
                    return .failure(Rejection("notifications.schedule: `repeat` is \"daily\" or \"weekly\""))
                }
                guard at != nil else { return .failure(Rejection("notifications.schedule: `repeat` needs `at`")) }
                repeating = kind
            }
            var tap: [String: Any] = ["id": id, "title": title]
            if let body { tap["body"] = body }
            if let url = object["url"] as? String { tap["url"] = url }
            if let data = object["data"], !(data is NSNull) {   // `data: null` from JS = none
                guard data is [String: Any] else { return .failure(Rejection("notifications.schedule: `data` must be an object")) }
                tap["data"] = data
            }
            guard let tapData = try? JSONSerialization.data(withJSONObject: tap),
                  let tapJson = String(data: tapData, encoding: .utf8) else {
                return .failure(Rejection("notifications.schedule: `data` is not serializable"))
            }
            return .success(Request(id: id, title: title, body: body, at: at, repeating: repeating, tap: tapJson))
        }
    }

    private var center: UNUserNotificationCenter { .current() }

    // MARK: - The table's calls (main thread; `world` = the calling world's project, nil = unattributed)

    /// Schedule `request` — replacing the same id of `world` — and complete on the main thread with
    /// nil, or the reject reason. The permission is the caller's to have asked.
    func schedule(_ request: Request, world: String?, _ done: @escaping (String?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        if let body = request.body { content.body = body }
        content.sound = .default
        var info: [String: Any] = ["payload": request.tap]
        if let world { info["projectUuid"] = world }
        if let repeating = request.repeating { info["repeat"] = repeating.rawValue }
        content.userInfo = [LocalNotifications.key: info]

        let identifier = Self.namespace(world) + request.id
        let center = self.center
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: Self.trigger(request))) { error in
            if let error { print("[notifications] schedule: \(error.localizedDescription)") }
            onMainThread { done(error == nil ? nil : "unavailable") }
        }
    }

    /// Cancel `id` of `world` and remove it from the shade. Unknown id: nothing.
    func cancel(_ id: String, world: String?) {
        let identifiers = [Self.namespace(world) + id]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Cancel every pending notification of `world` and clear its shown ones.
    func cancelAll(world: String?) {
        let center = self.center
        let mine = Self.belongs(to: world)
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.filter(mine).map(\.identifier))
        }
        center.getDeliveredNotifications { notifications in
            center.removeDeliveredNotifications(withIdentifiers: notifications.map(\.request).filter(mine).map(\.identifier))
        }
    }

    /// The pending notifications of `world` — the JSON of a PendingNotification array — on the main
    /// thread. `at` is the trigger's next date (a repeating one: its next time).
    func pending(world: String?, _ done: @escaping (String) -> Void) {
        let mine = Self.belongs(to: world)
        center.getPendingNotificationRequests { requests in
            var list: [[String: Any]] = []
            for request in requests where mine(request) {
                guard let local = request.content.userInfo[AnyHashable(LocalNotifications.key)] as? [String: Any],
                      let payload = local["payload"] as? String, var entry = LocalNotifications.object(payload),
                      let next = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { continue }
                entry["at"] = Int64((next.timeIntervalSince1970 * 1000).rounded())
                if let repeating = local["repeat"] as? String { entry["repeat"] = repeating }
                list.append(entry)
            }
            let json = (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            onMainThread { done(json) }
        }
    }

    /// The parked tap's JSON when it is `world`'s (its project, or both unattributed), else nil.
    func launchTap(world: String?) -> String? {
        guard let parked, parked.projectUuid == world else { return nil }
        return parked.json
    }

    // MARK: - Delivery (LeCodesAppHooks, main thread)

    /// Whether `notification` is one this service scheduled.
    static func owns(_ notification: UNNotification) -> Bool {
        notification.request.content.userInfo[AnyHashable(key)] != nil
    }

    /// The tap that cold-started the app: parked for its project's world, the launch URL seeded to
    /// that project (an unattributed one: the boot world is the one it reaches).
    func coldStart(_ response: UNNotificationResponse) {
        guard let engine, let tap = Self.tap(response.notification) else { return }
        parked = tap
        coldStartHandledId = response.notification.request.identifier
        if let uuid = tap.projectUuid { engine.setLaunchUrl("https://le.codes/qr/\(uuid)") }
    }

    /// A tap while the process is alive.
    func didReceive(_ response: UNNotificationResponse) {
        guard let engine, let tap = Self.tap(response.notification) else { return }
        // The cold-start tap again — already routed (see the header).
        if coldStartHandledId == response.notification.request.identifier {
            coldStartHandledId = nil
            return
        }
        if tap.projectUuid == engine.currentProjectUuid {
            Core.emitAppEvent("notification", data: tap.json)
        } else if let uuid = tap.projectUuid {
            parked = tap
            engine.openLauncher(withUrl: "https://le.codes/qr/\(uuid)")
        }
    }

    // MARK: - Internals

    /// A tap's routing: the scheduling world's project and the NotificationTap's JSON.
    private struct Tap {
        let projectUuid: String?
        let json: String
    }

    /// The tap that launched (or re-routed to) a world, served by `launchTap`.
    private var parked: Tap? = nil
    /// The identifier of the cold-start tap, until its didReceive redelivery is seen.
    private var coldStartHandledId: String? = nil

    private static func tap(_ notification: UNNotification) -> Tap? {
        guard let local = notification.request.content.userInfo[AnyHashable(key)] as? [String: Any],
              let json = local["payload"] as? String else { return nil }
        return Tap(projectUuid: local["projectUuid"] as? String, json: json)
    }

    private static func namespace(_ world: String?) -> String { (world ?? "") + "|" }

    /// A request of `world`'s namespace that this service scheduled.
    private static func belongs(to world: String?) -> (UNNotificationRequest) -> Bool {
        let prefix = namespace(world)
        return { $0.identifier.hasPrefix(prefix) && $0.content.userInfo[AnyHashable(LocalNotifications.key)] != nil }
    }

    private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// No future `at`: nil (shown now). Whole seconds rounded up, so the components never name a
    /// second before `at`.
    private static func trigger(_ request: Request) -> UNNotificationTrigger? {
        guard let at = request.at else { return nil }
        let date = Date(timeIntervalSince1970: (at / 1000).rounded(.up))
        let calendar = Calendar.current
        switch request.repeating {
        case .daily?:
            return UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.hour, .minute, .second], from: date), repeats: true)
        case .weekly?:
            return UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.weekday, .hour, .minute, .second], from: date), repeats: true)
        case nil:
            guard date > Date() else { return nil }
            return UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
        }
    }
}
