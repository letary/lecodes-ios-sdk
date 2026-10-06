// What the UI renderer needs from this host (LeCodesUIKit's RendererServices) — the twin of
// hosts/android's HostRendererServices.kt: the presentation calls forwarded to the engine's root
// view, fonts, toasts, native views, the buffer store, fetch, media players. Every member only
// forwards, reading the services at call time.
import AVFoundation
import Foundation
import LeCodesCore
import LeCodesUIKit
import UIKit

final class HostRendererServices: RendererServices {
    weak var engine: LeCodesEngine?

    // MARK: - presentation → the root view

    func openView(_ dest: PresentedDest, above: Bool) { engine?.rootView?.openDest(dest, above: above) }
    func dropView(_ dest: PresentedDest) { engine?.rootView?.dropDest(dest) }
    func closeView() { engine?.rootView?.closeDest() }
    func widgetOpen(_ node: UINode, owner: WidgetOwner) { engine?.rootView?.widgetOpen(node, owner: owner) }
    func widgetClose(_ node: UINode) { engine?.rootView?.widgetClose(node) }
    func nodeReleased(_ node: UINode) { engine?.rootView?.nodeReleased(node) }

    // MARK: - fonts: swap-not-await

    /// Always resolves: a face that fails to load is a fallback, not an app error (iOS, Android
    /// and the desktop agree). An `id:<bufferId>` face registers synchronously, before the first
    /// layout; a URL is fetched and swapped in when it lands.
    func registerFont(url: String, fontFamily: String, weight: Int, style: Int, onComplete: JSCallback, onReject: JSCallback) {
        if url.hasPrefix("id:"), let id = Int32(url.dropFirst(3)) {
            if let data = Buffers.get(id) { FontManager.register(data: data, family: fontFamily, weight: weight, style: style) }
            Core.resolve(onComplete, reject: onReject)
            return
        }
        _ = fetch(url: url, onSuccess: { data in
            FontManager.register(data: data, family: fontFamily, weight: weight, style: style)
            Core.resolve(onComplete, reject: onReject)
        }, onError: {
            Core.resolve(onComplete, reject: onReject)
        })
    }

    // MARK: - toasts

    /// The renderer's ToastView over the root view; without one (an engine-only embedder) the
    /// message goes to the log.
    func showToast(message: String, duration: Int) {
        guard let root = engine?.rootView else { print("[toast] \(message)"); return }
        root.showToast(message, durationMs: duration)
    }

    // MARK: - native views

    func isViewSupported(_ name: String) -> Bool { engine?.nativeViews.isSupported(name) ?? false }
    func viewVersion(_ name: String) -> Int32 { engine?.nativeViews.version(name) ?? 0 }
    func viewCall(viewId: Int, method: String, args: WireIn, onComplete: JSCallback, onReject: JSCallback) {
        guard let engine else { Core.reject(onComplete, reject: onReject, message: "no engine"); return }
        engine.nativeViews.call(Int32(viewId), method, args, onComplete, onReject)
    }
    func nativeView(viewId: Int, name: String?, paramsJson: String?) -> UIView {
        engine?.nativeViews.ensure(viewId: Int32(viewId), viewName: name ?? "", paramsJson: paramsJson ?? "null")?.view ?? NativeViews.placeholder(name ?? "")
    }

    // MARK: - the buffer store, fetch, media

    func buffer(id: Int) -> Data? { Buffers.get(Int32(id)) }

    func fetch(url: String, onSuccess: @escaping (Data) -> Void, onError: @escaping () -> Void) -> Cancel {
        guard let u = URL(string: url) else { onError(); return Task(nil) }
        let task = URLSession.shared.dataTask(with: u) { data, _, _ in
            if let data { onSuccess(data) } else { onError() }
        }
        task.resume()
        return Task(task)
    }
    private final class Task: Cancel {
        let task: URLSessionDataTask?
        init(_ task: URLSessionDataTask?) { self.task = task }
        func cancel() { task?.cancel() }
    }

    func mediaPlayer(id: Int) -> AVPlayer? { engine?.media.players.player(Int32(id)) }
}
