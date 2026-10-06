// The open widgets of one LeCodesView — the twin of hosts/android's WidgetHost.kt: where each is
// mounted, whether it shows, and its layout. A widget MOUNTS INSIDE its owner's view (the Apple
// model): clipping and riding the owner's motion — a screen transition, a pager swipe — come from
// the view hierarchy for free. Owners that cannot take a child view keep it on the root view: a
// scene, a native view, a video are surfaces.
//
// Three invariants, learned the hard way on both phones:
//  · mount on the owner view's EXISTENCE, not on the owner being presented — a pager builds a view
//    for every tab, so a widget attached to a tab that is not showing still belongs in it and
//    swipes in WITH the tab;
//  · the widget's view is ALWAYS parented — to its owner or to the root;
//  · whether it SHOWS is a separate flag from where it is mounted: an unpresented owner leaves the
//    widget parked on the root and hidden.
import LeCodesCore
import LeCodesUIKit
import UIKit

final class WidgetHost {
    private unowned let root: LeCodesView

    private final class Entry {
        let node: UINodeWidget
        var owner: WidgetOwner
        /// The root view for a global overlay, the owner's view for an embedded one.
        var host: UIView?
        init(node: UINodeWidget, owner: WidgetOwner) { self.node = node; self.owner = owner }
    }
    /// One entry per open widget, in open order (the z-order among global overlays).
    private var entries: [Entry] = []

    init(root: LeCodesView) { self.root = root }

    var roots: [UINodeWidget] { entries.map { $0.node } }
    func contains(_ node: UINode) -> Bool { entries.contains { $0.node === node } }
    /// The view a widget is mounted in — the region its keyboard overlap is measured against.
    func hostOf(_ node: UINode) -> UIView? { entries.first { $0.node === node }?.host }

    /// HostUI.widgetOpen. A re-show binds to the owner passed NOW (the SDK contract).
    func open(_ node: UINodeWidget, owner: WidgetOwner) {
        entries.removeAll { $0.node === node }
        let entry = Entry(node: node, owner: owner)
        entries.append(entry)
        place(entry)
        // A scrim promises an inert background, so a keyboard still floating over it belongs to a
        // field the user can no longer reach. Blur it — unless the focused input is INSIDE the
        // widget that just opened (a sheet with its own composer), the normal case.
        if node.overlayColor != nil, root.keyboard.keyboardInset > 0, root.keyboard.focusedRoot() !== node {
            root.keyboard.hideKeyboard()
        }
    }

    /// HostUI.widgetClose: hidden — the subtree STAYS (the handle owns it; a later show brings it
    /// back through `open`); the runtime says when it is freed (releaseNode).
    func close(_ node: UINode) {
        guard let i = entries.firstIndex(where: { $0.node === node }) else { return }
        let entry = entries.remove(at: i)
        entry.node.removeOverlay()
        entry.node.view.removeFromSuperview()
        root.keyboard.onRootReleased(node)
    }

    /// Re-resolve where every widget belongs: on each destination change, and whenever a pager
    /// page is built or released (nothing else notices its view appearing).
    func updateAttached() {
        for e in entries { place(e) }
    }

    /// The root's size changed: every widget's box and scrim follow.
    func layoutAll() {
        for e in entries { layout(e) }
    }

    /// Above the presented screen (a screen just mounted took the top): every global overlay and
    /// its scrim, in open order.
    func bringGlobalsToFront() {
        for e in entries where e.host === root { e.node.bringToFront() }
    }

    // MARK: - placement

    private func ownerPresented(_ owner: WidgetOwner) -> Bool {
        switch owner.kind {
        case DestKind.none: return true
        case DestKind.screen: return owner.node.map { root.currentScreen === $0 || UINodePager.isCurrentPage($0) } ?? false
        default: return root.destKind == owner.kind && root.destId == owner.id   // the surface kinds, with their step
        }
    }

    /// The owner's own view when a widget can be mounted into it — resolved on the view's
    /// EXISTENCE: the presented screen's, or a pager page's (every tab's, not just the one on
    /// screen: the widget sits in the tab's cell and swipes in WITH it).
    private func ownerContainer(_ owner: WidgetOwner) -> UIView? {
        guard owner.kind == DestKind.screen, let node = owner.node else { return nil }
        if root.currentScreen === node { return node.view }
        if UINodePager.isLivePage(node) { return node.view }
        return nil
    }

    /// Put the widget where its owner is now, and show it iff it can be seen there.
    private func place(_ entry: Entry) {
        let node = entry.node
        let view = node.view
        let container = ownerContainer(entry.owner)
        let target: UIView = container ?? root
        // Embedded, the hierarchy shows and hides it with its owner; parked on the root, the owner
        // has to be the presented one.
        let presented = container != nil || ownerPresented(entry.owner)
        if entry.host !== target || view.superview !== target {
            entry.host = target
            node.removeOverlay()
            view.removeFromSuperview()
            target.addSubview(view)
            node.applyOverlay()   // needs the view attached to find its parent
            node.bringToFront()
        }
        let hidden = !presented
        if view.isHidden != hidden {
            view.isHidden = hidden
            node.overlay?.isHidden = hidden
        }
        layout(entry)
    }

    /// Lay a widget out in its host's box. Embedded → the owner view's size, so `bottom: 0` means
    /// the page's bottom edge (a page above a tab bar is shorter than the window); parked on the
    /// root → the frame viewport, the engine's default. The whole job — the engine's box, the yoga
    /// pass, the scrim's frame, the view's frame — so every caller gets the same answer and a
    /// widget shown mid-frame lands on the very next one.
    private func layout(_ entry: Entry) {
        guard let target = entry.host else { return }
        let embedded = target !== root
        let size = embedded && target.bounds.width > 0 && target.bounds.height > 0 ? target.bounds.size : root.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        Core.setWidgetBox(entry.node.id, width: embedded ? Float(size.width) : 0, height: embedded ? Float(size.height) : 0)
        // Short by the keyboard overlap iff this widget is the shrunk root — the runtime's rule,
        // so this out-of-band recalc and the per-tick pass agree.
        CreatorUI.calculateWidget(entry.node.id, width: Float(size.width), height: Core.rootLayoutHeight(entry.node.id, height: Float(size.height)))
        entry.node.overlay?.place(CGRect(origin: .zero, size: target.bounds.size))
        entry.node.updateLayout()   // a structural apply: the box just calculated onto the view
    }
}
