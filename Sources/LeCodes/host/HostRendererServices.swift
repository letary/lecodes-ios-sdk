// What the UI renderer needs from this host (LeCodesUIKit's RendererServices) — the twin of
// hosts/android's HostRendererServices.kt: the presentation calls forwarded to the engine's root
// view, fonts, toasts, native views, host nodes, the buffer store, fetch, media players. Every member only
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
    func layerOpen(_ node: UINode, surface: Bool) { engine?.rootView?.layerOpen(node, surface: surface) }
    func layerClose(_ node: UINode) { engine?.rootView?.layerClose(node) }
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
        _ = get(url: url, cache: "", priority: URLSessionTask.defaultPriority, onSuccess: { data, _ in
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

    // MARK: - a flow's input → the root view

    func debugInput(kind: Int32, x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat, text: String) -> Bool {
        engine?.rootView?.debugInput(kind: kind, x: x, y: y, dx: dx, dy: dy, text: text) ?? false
    }

    // MARK: - host nodes

    func nodeVersion(_ kind: String) -> Int32 { engine?.hostNodes.version(kind) ?? 0 }
    func nodeCall(node: Int, method: String, args: WireIn, onComplete: JSCallback, onReject: JSCallback) {
        guard let engine else { Core.reject(onComplete, reject: onReject, message: "no engine"); return }
        engine.hostNodes.call(node, method, args, onComplete, onReject)
    }
    func makeHostNode(node: Int, kind: String, invalidateSize: @escaping () -> Void) -> HostNodeContent? {
        engine?.hostNodes.make(node: node, kind: kind, invalidateSize: invalidateSize)
    }
    func hostNodeReleased(node: Int) { engine?.hostNodes.destroy(node: node) }

    // MARK: - the buffer store, fetch, media

    func buffer(id: Int) -> Data? { Buffers.get(Int32(id)) }

    /// The renderer's loads are pictures: behind the app's own requests. The mode is carried out
    /// by the host's one function (CachedHTTP), so an image's copy and a fetch's are the same one.
    func fetch(url: String, cache: String, onSuccess: @escaping (Data, Int) -> Void, onError: @escaping () -> Void) -> Cancel {
        get(url: url, cache: cache, priority: URLSessionTask.lowPriority, onSuccess: onSuccess, onError: onError)
    }
    func keepCopy(url: String, data: Data) { CachedHTTP.keep(url: url, data: data) }

    private func get(url: String, cache: String, priority: Float, onSuccess: @escaping (Data, Int) -> Void, onError: @escaping () -> Void) -> Cancel {
        guard let u = URL(string: url) else { onError(); return NoRequest() }
        return CachedHTTP.request(URLRequest(url: u), url: url, cache: cache, priority: priority) { result in
            switch result {
            case .success(let answer): onSuccess(answer.data, answer.status)
            case .failure: onError()
            }
        }
    }
    private final class NoRequest: Cancel {
        func cancel() {}
    }

    func mediaPlayer(id: Int) -> AVPlayer? { engine?.media.players.player(Int32(id)) }
}

extension CachedHTTP.Call: Cancel {}
