// The registerNode registry (docs/plans/host-node-plan.md) — the twin of NativeViews for HOST NODES:
// a plugin registers a factory per node kind (`engine.registerNode("tabbar", version:) { channel in
// … }`, which the generated `<Name>NodeGlue.register(in:_:)` wraps), and the renderer's holder
// (renderers/uikit UINodeHost) asks for an instance when the SDK creates a node of that kind — one
// instance per node, keyed by the node id (the runtime's node pointer, the renderer's id), made at the
// node's first `kind` write and destroyed when the runtime releases the node. The SDK's
// `HostNodeElement` talks to it over HostUI: `nodeVersion` (what `supported` asks) and `nodeCall`
// (the methods, settled through ChannelSettle like a view's); the instance's events go up through
// its channel (Core.nodeEmit → TREE_EVENT_NODE_EVENT → the element's listeners). Main thread, but
// for what a member says otherwise.
import Foundation
import UIKit
import LeCodesCore
import LeCodesUIKit

/// The size a host node is asked to fit, in points: a nil side is unconstrained; an `…AtMost` side is
/// a maximum, any other given side the exact size.
public struct HostNodeConstraints {
    public var width: CGFloat?
    public var height: CGFloat?
    public var widthAtMost: Bool
    public var heightAtMost: Bool

    public init(width: CGFloat?, height: CGFloat?, widthAtMost: Bool = false, heightAtMost: Bool = false) {
        self.width = width
        self.height = height
        self.widthAtMost = widthAtMost
        self.heightAtMost = heightAtMost
    }
}

/// What a host node's instance tells the app and the holder, handed to the factory. Any thread. Once
/// the node is released it says nothing: an event of a destroyed instance is dropped here.
public struct HostNodeChannel {
    private let node: Int
    private let link: HostNodeLink

    init(node: Int, link: HostNodeLink) {
        self.node = node
        self.link = link
    }

    /// An event to the element's listeners; the payload is data (ChannelSettle.resolve says what) or nil.
    public func emit(_ event: String, _ payload: Any? = nil) {
        guard link.isAlive else { return }
        Core.nodeEmit(node, event: event) { out in if let payload { out.json(payload) } }
    }

    /// The same with the payload WRITTEN (the generated events of a contract); nothing written = no payload.
    public func emit(_ event: String, writing write: (WireOut) -> Void) {
        guard link.isAlive else { return }
        Core.nodeEmit(node, event: event, writing: write)
    }

    /// The content changed size: the holder measures the node again before the next frame (a node the
    /// SDK created with the measure flag — the contract's `measure: true`; for another it is nothing).
    public func invalidateSize() { link.invalidateSize() }
}

/// One host node of a plugin: `view` is laid out over the node's box and painted under the box paint
/// (the holder's); the props, the styles the contract lists and the measure come from the holder on
/// the main thread, a call's settle may complete from any thread; `destroy` runs when the node is
/// released. The generated `<Name>NodeInstance` extension implements all of it but `view`, `destroy`
/// and — when the contract says `measure: true` — `measure`.
public protocol HostNodeInstance: AnyObject {
    var view: UIView { get }
    /// A prop the SDK wrote, as its wire text (nil = cleared): the generated glue decodes it.
    func setProperty(_ name: String, _ value: String?)
    /// A color style of the node's paint record, as the core resolved it; nil = none is set.
    func setStyle(_ name: String, color: UIColor?)
    /// A number style of the node's paint record (a length in logical px); nil = none is set.
    func setStyle(_ name: String, number: Double?)
    /// The node's size within `c`: asked on a layout (a node created with the measure flag only), and
    /// again after the channel's `invalidateSize()`.
    func measure(_ c: HostNodeConstraints) -> CGSize
    /// A method of the SDK's element; settle exactly once.
    func call(_ method: String, wire args: WireIn, _ settle: ChannelSettle)
    /// The instance paints its background and backdrop (`paints: "self"`): the holder leaves them.
    var paintsSelf: Bool { get }
    func destroy()
}

public extension HostNodeInstance {
    func destroy() {}
}

public typealias HostNodeFactory = (_ channel: HostNodeChannel) -> HostNodeInstance

/// The tie between an instance's channel and its holder: the holder's re-measure (a closure that holds
/// the holder weakly), and whether the node is still there. Its channel may be used from any thread.
final class HostNodeLink {
    private let lock = NSLock()
    private var alive = true
    private let remeasure: () -> Void

    init(remeasure: @escaping () -> Void) { self.remeasure = remeasure }

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return alive
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        alive = false
    }

    func invalidateSize() {
        guard isAlive else { return }
        if Thread.isMainThread { remeasure(); return }
        DispatchQueue.main.async { [self] in if isAlive { remeasure() } }
    }
}

public final class HostNodes {
    private var factories: [String: HostNodeFactory] = [:]
    private var versions: [String: Int32] = [:]
    /// The live instances by node id, each behind the adapter the holder drives.
    private var instances: [Int: Live] = [:]

    public init() {}

    /// `version` = the contract version the half was generated from (1 for one written by hand).
    func register(_ kind: String, version: Int32 = 1, _ factory: @escaping HostNodeFactory) {
        if factories[kind] != nil {
            print("LeCodes: registerNode(\"\(kind)\") replaces an existing registration — plugin name collision? Last one wins.")
        }
        factories[kind] = factory
        versions[kind] = version
    }

    public func isRegistered(_ kind: String) -> Bool { factories[kind] != nil }
    /// HostUI.nodeVersion: 0 = no such kind.
    public func version(_ kind: String) -> Int32 { versions[kind] ?? 0 }

    /// The holder's instance for node `node` of `kind`, made now; nil = no factory for the kind. A
    /// node id the runtime reused while an instance of its previous node was alive drops that one.
    func make(node: Int, kind: String, invalidateSize: @escaping () -> Void) -> HostNodeContent? {
        destroy(node: node)
        guard let factory = factories[kind] else { return nil }
        let link = HostNodeLink(remeasure: invalidateSize)
        let live = Live(factory(HostNodeChannel(node: node, link: link)), link)
        instances[node] = live
        return live
    }

    /// HostUI.nodeCall: settle the pair exactly once. `args` is valid for this call only.
    func call(_ node: Int, _ method: String, _ args: WireIn, _ onComplete: JSCallback, _ onError: JSCallback) {
        let settle = ChannelSettle(onComplete, onError)
        guard let live = instances[node] else { return settle.reject("host node call \(method): the node has no instance") }
        live.instance.call(method, wire: args, settle)
    }

    /// The node was released: its instance goes; its channel says nothing from here on.
    func destroy(node: Int) {
        guard let live = instances.removeValue(forKey: node) else { return }
        live.link.close()
        live.instance.destroy()
    }

    /// The world swap / the engine's teardown: every instance goes.
    func destroyAll() {
        let all = instances.values
        instances.removeAll()
        for live in all {
            live.link.close()
            live.instance.destroy()
        }
    }

    /// The instance as the holder drives it (the renderer's HostNodeContent).
    private final class Live: HostNodeContent {
        let instance: HostNodeInstance
        let link: HostNodeLink
        init(_ instance: HostNodeInstance, _ link: HostNodeLink) {
            self.instance = instance
            self.link = link
        }
        var view: UIView { instance.view }
        var paintsSelf: Bool { instance.paintsSelf }
        func setProperty(_ name: String, _ value: String?) { instance.setProperty(name, value) }
        func setStyle(_ name: String, color: UIColor?) { instance.setStyle(name, color: color) }
        func setStyle(_ name: String, number: Double?) { instance.setStyle(name, number: number) }
        func measure(width: CGFloat?, widthAtMost: Bool, height: CGFloat?, heightAtMost: Bool) -> CGSize {
            instance.measure(HostNodeConstraints(width: width, height: height, widthAtMost: widthAtMost, heightAtMost: heightAtMost))
        }
    }
}
