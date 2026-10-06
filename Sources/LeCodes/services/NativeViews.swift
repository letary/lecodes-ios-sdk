// The registerView registry (docs/navigation-presentable-plan.md): the host registers named view
// factories (`engine.registerView("qrScanner") { params, channel in … }`) and the SDK's NativeView
// elements talk to them over HostUI.viewCall (the call / event protocol shared with the
// service channel: values, ChannelSettle.swift). One SDK NativeView instance (its stable `viewId`) maps to at most one live
// native instance, reused across fullscreen / embedded mounts — that reuse IS the promotion
// semantics; instances are created lazily at mount time by the renderer (renderers/uikit) and
// destroyed on the world swap (viewIds restart per project). Main thread only.
import Foundation
import UIKit
import LeCodesCore

/// The event channel handed to a view factory — `emit` delivers an event to the SDK element's
/// listeners. Any thread; the payload is data (ChannelSettle.resolve says what) or nil.
public struct NativeViewChannel {
    private let viewId: Int32
    public init(viewId: Int32) { self.viewId = viewId }
    public func emit(_ event: String, _ payload: Any? = nil) {
        Core.viewEmit(viewId: viewId, event: event) { out in if let payload { out.json(payload) } }
    }
    /// The same with the payload WRITTEN (the generated events of a contract); nothing written =
    /// no payload.
    public func emit(_ event: String, writing write: (WireOut) -> Void) {
        Core.viewEmit(viewId: viewId, event: event, writing: write)
    }
}

/// One live plugin view: `view` is mounted as a fullscreen destination or an embedded node;
/// `call` settles asynchronously; `destroy` runs when the instance is evicted.
public protocol NativeViewInstance: AnyObject {
    var view: UIView { get }
    func call(_ method: String, _ args: [Any], _ settle: ChannelSettle)
    func destroy()
}

public extension NativeViewInstance {
    func call(_ method: String, _ args: [Any], _ settle: ChannelSettle) { settle.reject("Unknown method: \(method)") }
    func destroy() {}
}

/// A view that reads its arguments off the wire itself (the GENERATED glue of a contract): the host
/// hands it the runtime's value, no Foundation objects are made of it.
public protocol WireNativeViewInstance: NativeViewInstance {
    func call(_ method: String, wire args: WireIn, _ settle: ChannelSettle)
}

public extension WireNativeViewInstance {
    /// The way of a half written by hand, for a caller that holds Foundation's objects.
    func call(_ method: String, _ args: [Any], _ settle: ChannelSettle) {
        WireIn.of(args) { call(method, wire: $0, settle) }
    }
}

public typealias NativeViewFactory = (_ params: Any?, _ channel: NativeViewChannel) -> NativeViewInstance

public final class NativeViews {
    private var factories: [String: NativeViewFactory] = [:]
    private var versions: [String: Int32] = [:]

    private struct Live {
        let instance: NativeViewInstance
        let wired: WireNativeViewInstance?   // the same instance, when it reads the wire itself
        let viewName: String
        let paramsJson: String
    }
    private var instances: [Int32: Live] = [:]

    public init() {}

    /// `version` = the contract version the half was generated from (1 for one written by hand).
    func register(_ name: String, version: Int32 = 1, _ factory: @escaping NativeViewFactory) {
        if factories[name] != nil {
            print("LeCodes: registerView(\"\(name)\") replaces an existing registration — plugin name collision? Last one wins.")
        }
        factories[name] = factory
        versions[name] = version
    }

    public func isSupported(_ name: String) -> Bool { factories[name] != nil }
    /// HostUI.viewVersion: 0 = no such view.
    public func version(_ name: String) -> Int32 { versions[name] ?? 0 }

    /// The live instance for `viewId`, created on first use; recreated when the name or the params
    /// changed under a reused id (viewIds restart per project world). nil = no factory.
    public func ensure(viewId: Int32, viewName: String, paramsJson: String) -> NativeViewInstance? {
        if let live = instances[viewId] {
            if live.viewName == viewName && live.paramsJson == paramsJson { return live.instance }
            live.instance.destroy()
            instances[viewId] = nil
        }
        guard let factory = factories[viewName] else { return nil }
        let instance = factory(ChannelValues.params(paramsJson), NativeViewChannel(viewId: viewId))
        instances[viewId] = Live(instance: instance, wired: instance as? WireNativeViewInstance, viewName: viewName, paramsJson: paramsJson)
        return instance
    }

    public func instance(for viewId: Int32) -> NativeViewInstance? { instances[viewId]?.instance }

    /// The box shown for a name no factory is registered for (a plugin the shell did not link).
    static func placeholder(_ name: String) -> UIView {
        let label = UILabel()
        label.text = "NativeView \"\(name)\" is not registered"
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0.2, alpha: 1)
        return label
    }

    /// HostUI.viewCall: settle the pair exactly once. `args` is valid for this call only.
    public func call(_ viewId: Int32, _ method: String, _ args: WireIn, _ onComplete: JSCallback, _ onError: JSCallback) {
        let settle = ChannelSettle(onComplete, onError)
        guard let live = instances[viewId] else { settle.reject("NativeView call: no live instance for viewId \(viewId)"); return }
        if let wired = live.wired { wired.call(method, wire: args, settle) }
        else { live.instance.call(method, ChannelValues.args(args), settle) }
    }

    /// The world swap / the engine's teardown: every instance goes (the only points at which a
    /// viewId provably stops meaning anything — a dismissed destination keeps its warm instance).
    func destroyAll() {
        let live = instances.values.map { $0.instance }
        instances.removeAll()
        live.forEach { $0.destroy() }
    }
}
