// The iOS renderer's side of the host contract — `HostUI` of sdk/src/bridges/tree.d.ts
// (creator-pkg/host.gen.h, the Swift protocol in LeCodesCore's HostContract.swift). The runtime owns
// the UI tree; this table gets one call per structural change, content property or flag mask, keyed
// by node id, and keeps one UINode per id in Nodes. Events go back by id through Core.nodeEvent /
// Core.touch* / Core.nodeLayout. Presentation (openView, widgets), fonts, toasts and native views
// are the host's: they go through `services`, which the initializer also makes the renderer-wide
// `rendererServices`. The twin of renderers/android's HostUIRenderer.kt.
//
// Every optional slot is present: the generated glue reads them ONCE at bind.
import LeCodesCore
import UIKit

public final class HostUIRenderer: HostUI {
    private let services: RendererServices

    public init(services: RendererServices) {
        self.services = services
        rendererServices = services
        UINode.installMeasure()
    }

    // MARK: - structure

    public func nodeFactory(id: Int, type: String, parent: Int, index: Int32) {
        let node = Nodes.create(id, type)
        Nodes.put(id, node)
        if parent != 0 { attach(parent, node, Int(index)) }
    }

    private func attach(_ parentId: Int, _ child: UINode, _ index: Int) {
        guard let container = Nodes[parentId] as? UINodeContainer else { return }
        container.insert(child, at: index)
    }

    public func insertNode(parent: Int, child: Int, index: UInt16) {
        guard let c = Nodes[child] else { return }
        attach(parent, c, Int(index))
    }

    public func removeNode(parent: Int, child: Int) {
        guard let p = Nodes[parent] as? UINodeContainer, let c = Nodes[child] else { return }
        p.remove(c)
    }

    /// The runtime frees this node (its yoga node goes right after): drop the node and the map entry.
    public func releaseNode(id: Int) {
        guard let node = Nodes.remove(id) else { return }
        node.markRemoved()
        node.onRemoved()
        services.nodeReleased(node)
    }

    public func setPropertyString(id: Int, prop: String, value: String?) {
        Nodes[id]?.setProperty(prop, value)
    }

    public func setPropertyInt(id: Int, prop: String, value: Int32) {
        Nodes[id]?.setPropertyInt(prop, value)
    }

    public func setFlags(id: Int, mask: UInt32) {
        Nodes[id]?.flags = mask
    }

    // MARK: - presentation

    public func openView(kind: UInt8, node: Int, id: Int32, viewName: String, paramsJson: String, above: Bool) {
        services.openView(PresentedDest(kind: Int(kind), node: Nodes[node], id: Int(id), viewName: viewName, paramsJson: paramsJson),
                          above: above)
    }

    public func dropView(kind: UInt8, node: Int, id: Int32) {
        services.dropView(PresentedDest(kind: Int(kind), node: Nodes[node], id: Int(id), viewName: nil, paramsJson: nil))
    }

    public func closeView() {
        services.closeView()
    }

    public var isViewSupported: ((String) -> Bool)? { { [services] name in services.isViewSupported(name) } }

    public var viewVersion: ((String) -> Int32)? { { [services] name in services.viewVersion(name) } }

    public var viewCall: ((Int32, String, WireIn, JSCallback, JSCallback) -> Void)? {
        { [services] viewId, method, args, onComplete, onReject in
            services.viewCall(viewId: Int(viewId), method: method, args: args, onComplete: onComplete, onReject: onReject)
        }
    }

    public func widgetOpen(node: Int, ownerKind: UInt8, ownerId: Int32, ownerNode: Int) {
        guard let widget = Nodes[node] else { return }
        let owner = Int(ownerKind) == DestKind.none ? WidgetOwner.global : WidgetOwner(kind: Int(ownerKind), id: Int(ownerId), node: Nodes[ownerNode])
        services.widgetOpen(widget, owner: owner)
    }

    public func widgetClose(node: Int) {
        guard let widget = Nodes[node] else { return }
        services.widgetClose(widget)
    }

    public func registerFont(url: String, fontFamily: String, weight: Int32, style: Int32, onComplete: JSCallback, onReject: JSCallback) {
        services.registerFont(url: url, fontFamily: fontFamily, weight: Int(weight), style: Int(style), onComplete: onComplete, onReject: onReject)
    }

    public func showToast(message: String, duration: Int32) {
        services.showToast(message: message, duration: Int(duration))
    }

    // MARK: - the pulls

    public func getButtonPressed(node: Int) -> Bool { (Nodes[node] as? UINodeButton)?.isPressed ?? false }

    /// The input's live text ("" for anything else).
    public func getTextValue(node: Int) -> String { (Nodes[node] as? UINodeInput)?.textValue ?? "" }

    /// nil → JS null: the node is not mounted or has never been laid out.
    public var getBoundingRect: ((Int) -> [Float]?)? { { node in Nodes[node]?.boundingRect() } }

    // MARK: - gestures

    /// A node's touchStart / longPress listener took the gesture: keep feeding this pointer.
    public var touchHandler: ((Int32, Bool, UInt8, Int) -> Void)? {
        { pointerId, hasMove, claim, node in TouchHandlers.add(pointerId, hasMove: hasMove, claim: claim, node: node) }
    }
    /// A long press was handled — the button swallows the click that would follow the release.
    public var longPressHandler: ((Int32, Int) -> Void)? { { pointerId, _ in TouchHandlers.markLongPress(pointerId) } }

    // MARK: - vlist / pager

    /// The runtime changed the pager's tabs: "select" / "content" (remount from the pager pulls).
    public var pagerCommand: ((Int, String, Bool) -> Void)? {
        { node, cmd, animated in (Nodes[node] as? UINodePager)?.pagerView.handleCommand(cmd, animated: animated) }
    }
    /// A page became the top of the current tab's stack: into the cell, over or under the one
    /// shown there, which stays until the runtime drops it (the runtime moves both).
    public var pagerShowPage: ((Int, Int, Bool) -> Void)? {
        { node, page, above in
            guard let pager = Nodes[node] as? UINodePager, let page = Nodes[page] else { return }
            pager.pagerView.showPage(page, above: above)
        }
    }
    public var pagerDropPage: ((Int, Int) -> Void)? {
        { node, page in
            guard let pager = Nodes[node] as? UINodePager, let page = Nodes[page] else { return }
            pager.pagerView.dropPage(page)
        }
    }
    /// A page root was attached / released — every tab, not just the visible one: the widgets
    /// attached to a page mount INTO it, and a page appearing is invisible to the destination model.
    public var pagerPageMounted: ((Int, Bool) -> Void)? {
        { _, _ in (UINode.appRoot as? UIRootHost)?.updateAttachedWidgets() }
    }

    /// The runtime's one vlist call: `animated` false = anchoring / a clamp (buffered, applied after
    /// the content height), true = a user scroll command.
    public func vlistScroll(node: Int, scrollY: Float, animated: Bool) {
        (Nodes[node] as? UINodeVList)?.applyScroll(CGFloat(scrollY), animated: animated)
    }

    // MARK: - host-driven tweens

    /// A tween track on a layer property plays on Core Animation (LayerTween); every other prop
    /// stays the runtime's, one write per frame.
    public var tweenClaim: ((Int, String, Int32, UnsafeBufferPointer<Float>, Float, Float, Int32, Bool, Float) -> Bool)? {
        { node, prop, lanes, samples, durationMs, delayMs, iterations, pingPong, rate in
            guard let n = Nodes[node] else { return false }
            return LayerTween.claim(n, prop: prop, lanes: Int(lanes), samples: samples, durationMs: durationMs, delayMs: delayMs,
                                    iterations: iterations, pingPong: pingPong, rate: rate)
        }
    }
    public var tweenRelease: ((Int, String, UInt8) -> Void)? {
        { node, prop, _ in if let n = Nodes[node] { LayerTween.release(n, prop: prop) } }
    }
}
