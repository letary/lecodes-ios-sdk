// The app-delegate hook surface for plugins (docs/push-plan.md "plugin extraction") — the same
// file the old SDK carried (utils/AppHooks.swift), unchanged in its API: the push plugin attaches a
// LeCodesNotificationHandler, the host app forwards the UIApplicationDelegate / scene-connect
// moments it cannot see itself.
////  Plugins register against the engine (registerView/registerService), but some platform
//  capabilities also need UIApplicationDelegate / scene-connect moments the plugin cannot
//  implement itself — and iOS only populates `connectionOptions.notificationResponse`
//  when the UNUserNotificationCenter delegate is installed while the app is still
//  launching, BEFORE any plugin has registered. So the host app forwards those moments
//  here, and the SDK buffers them until a handler (the push plugin) attaches:
//
//      // AppDelegate.didFinishLaunching — the notification-center delegate must be in
//      // place before the first callback can fire:
//      LeCodesAppHooks.install()
//      // AppDelegate APNs callbacks:
//      LeCodesAppHooks.remoteNotificationsToken(deviceToken)
//      LeCodesAppHooks.remoteNotificationsError(error)
//      // SceneDelegate.willConnectTo, before the root VC starts the JS world:
//      if let response = connectionOptions.notificationResponse {
//          LeCodesAppHooks.coldStartNotification(response)
//      }
//
//  Everything is buffered, so forward-then-register and register-then-forward both work.
//  Drain order on attach is cold-start response FIRST, then buffered taps — iOS reports a
//  launching tap twice (connectionOptions + delegate didReceive) and the handler's dedup
//  relies on seeing the cold-start delivery before the redelivery.
//
//  Kept in the SDK deliberately: this file references only UserNotifications (no
//  usage-description / review flag for linking it). The privacy-flagged machinery —
//  CoreLocation, APNs registration, the le.codes backend calls — lives in the plugins.
//



import Foundation
import UIKit
import UserNotifications

/// What a notification-consuming plugin implements (the push plugin's PushManager).
/// All methods are called on the main thread.
public protocol LeCodesNotificationHandler: AnyObject {
    /// AppDelegate: didRegisterForRemoteNotificationsWithDeviceToken.
    func remoteNotificationsToken(_ token: Data)
    /// AppDelegate: didFailToRegisterForRemoteNotificationsWithError.
    func remoteNotificationsError(_ error: Error)
    /// The notification tap that cold-started this launch (connectionOptions.notificationResponse).
    func coldStart(_ response: UNNotificationResponse)
    /// Foreground receipt — decide the presentation options.
    func willPresent(_ notification: UNNotification,
                     completion: @escaping (UNNotificationPresentationOptions) -> Void)
    /// Tap while the process is alive.
    func didReceive(_ response: UNNotificationResponse, completion: @escaping () -> Void)
}

public enum LeCodesAppHooks {

    /// Call from application(_:didFinishLaunchingWithOptions:). Installs the SDK-owned
    /// notification-center delegate; with no handler attached it shows banners normally
    /// and buffers taps.
    public static func install() {
        UNUserNotificationCenter.current().delegate = proxy
    }

    // MARK: - Host-app forwards

    public static func remoteNotificationsToken(_ token: Data) {
        onMainThread {
            if let handler { handler.remoteNotificationsToken(token) } else { pendingToken = .success(token) }
        }
    }

    public static func remoteNotificationsError(_ error: Error) {
        onMainThread {
            if let handler { handler.remoteNotificationsError(error) } else { pendingToken = .failure(error) }
        }
    }

    public static func coldStartNotification(_ response: UNNotificationResponse) {
        onMainThread {
            if let handler { handler.coldStart(response) } else { pendingColdStart = response }
        }
    }

    // MARK: - Handler attach (the push plugin, from register(in:) on the main thread)

    public static func setNotificationHandler(_ newHandler: LeCodesNotificationHandler) {
        handler = newHandler
        if let response = pendingColdStart {
            pendingColdStart = nil
            newHandler.coldStart(response)
        }
        let taps = pendingResponses
        pendingResponses = []
        for response in taps { newHandler.didReceive(response) {} }
        if let token = pendingToken {
            pendingToken = nil
            switch token {
            case .success(let data): newHandler.remoteNotificationsToken(data)
            case .failure(let error): newHandler.remoteNotificationsError(error)
            }
        }
    }

    // MARK: - State (main-thread confined; delegate callbacks hop before touching it)

    private static var handler: LeCodesNotificationHandler? = nil
    private static var pendingColdStart: UNNotificationResponse? = nil
    private static var pendingResponses: [UNNotificationResponse] = []
    private static var pendingToken: Result<Data, Error>? = nil

    private static let proxy = NotificationCenterProxy()

    private final class NotificationCenterProxy: NSObject, UNUserNotificationCenterDelegate {

        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            onMainThread {
                if let handler = LeCodesAppHooks.handler {
                    handler.willPresent(notification, completion: completionHandler)
                } else {
                    completionHandler([.banner, .sound, .list])
                }
            }
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            onMainThread {
                if let handler = LeCodesAppHooks.handler {
                    handler.didReceive(response, completion: completionHandler)
                } else {
                    // Buffered for the handler; the system callback cannot wait for it.
                    LeCodesAppHooks.pendingResponses.append(response)
                    completionHandler()
                }
            }
        }
    }
}



/// Run on the main thread — now when already there, else posted (the old SDK's helper: the hooks and the plugins use it).
public func onMainThread(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
}
