// The LAYER roots the runtime shows (HostUI.layerOpen / layerClose — docs/plans/widgets-plan.md):
// the app layer, a presented surface's content layer. A layer is a pass-through root laid out by
// the runtime at the viewport; its children are
// widgets, which the runtime inserts under it like under a screen root (insertNode), so nothing
// here knows a widget: a widget's view is its parent container's, its box comes with the layout
// batch (a root of the batch, placed as a child of its outer root's view), its overlay is the
// renderer's (UINodeWidget.applyOverlay, under the widget in the same superview). The twin of
// hosts/android's LayerHost. The z-order: the app layer (`surface` false) is mounted ABOVE every
// destination, in open order — the top of the host's subviews, where nothing else is ever added (a
// screen goes in under `bottomAppLayerView`, LeCodesView.openScreen; a surface at 0); a surface's
// content layer (`surface` true) sits right over the surface, UNDER every screen — a screen covering
// the surface covers its widgets, the screen that leaves when the surface is pushed stays over them,
// and the ones of a surface that leaves are covered as the screen comes over them.
import LeCodesCore
import LeCodesUIKit
import UIKit

final class LayerHost {
    private unowned let root: LeCodesView
    private var open: [(node: UINode, view: UIView, surface: Bool)] = []

    init(root: LeCodesView) { self.root = root }

    /// Every open layer's root node, in open order (the z-order among layers).
    var roots: [UINode] { open.map { $0.node } }
    func contains(_ node: UINode) -> Bool { open.contains { $0.node === node } }
    /// The topmost surface layer's view: what a screen goes right above (the surface itself otherwise).
    var topSurfaceLayerView: UIView? { open.last(where: { $0.surface })?.view }
    /// The lowest app layer's view: what a screen goes right below (the top of the stack otherwise).
    var bottomAppLayerView: UIView? { open.first(where: { !$0.surface })?.view }

    /// HostUI.layerOpen: the layer's view — the app layer above what is shown, a surface's content
    /// right over the surface (above the surface layers opened before it), under the screens.
    func open(_ node: UINode, surface: Bool) {
        if contains(node) { return }
        let view = node.view
        view.removeFromSuperview()
        if surface {
            if let below = topSurfaceLayerView ?? root.surfaceBottom { root.insertSubview(view, aboveSubview: below) }
            else { root.insertSubview(view, at: 0) }
        } else {
            root.addSubview(view)   // the top: above the screens, in open order
        }
        open.append((node, view, surface))
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
}
