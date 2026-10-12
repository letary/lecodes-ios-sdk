// The LAYER roots the runtime shows (HostUI.layerOpen / layerClose — docs/plans/widgets-plan.md):
// the app layer, a presented surface's content layer. A layer is a pass-through root laid out by
// the runtime at the viewport, mounted ABOVE every destination in open order; its children are
// widgets, which the runtime inserts under it like under a screen root (insertNode), so nothing
// here knows a widget: a widget's view is its parent container's, its box comes with the layout
// batch (a root of the batch, placed as a child of its outer root's view), its overlay is the
// renderer's (UINodeWidget.applyOverlay, under the widget in the same superview). The twin of
// hosts/android's LayerHost.
import LeCodesCore
import LeCodesUIKit
import UIKit

final class LayerHost {
    private unowned let root: LeCodesView
    private var open: [(node: UINode, view: UIView)] = []

    init(root: LeCodesView) { self.root = root }

    /// Every open layer's root node, in open order (the z-order among layers).
    var roots: [UINode] { open.map { $0.node } }
    func contains(_ node: UINode) -> Bool { open.contains { $0.node === node } }

    /// HostUI.layerOpen: the layer's view, above what is shown.
    func open(_ node: UINode) {
        if contains(node) { return }
        let view = node.view
        view.removeFromSuperview()
        root.addSubview(view)   // the end: above the screens and the surface, in open order
        open.append((node, view))
        if root.bounds.width > 0, root.bounds.height > 0 { node.updateLayout() }
    }

    /// HostUI.layerClose: hidden — the subtree STAYS (the handle owns it); releaseNode says when it is gone.
    func close(_ node: UINode) {
        guard let i = open.firstIndex(where: { $0.node === node }) else { return }
        open.remove(at: i).view.removeFromSuperview()
    }

    /// The host's box landed: every layer's content was laid out at it by the runtime.
    func layoutAll() {
        for entry in open { entry.node.updateLayout() }
    }

    /// The layers over everything again (a screen just mounted took the top).
    func bringToFront() {
        for entry in open { root.bringSubviewToFront(entry.view) }
    }
}
