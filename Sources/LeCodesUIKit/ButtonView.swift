// The button's view — the old host's NodeButton (a UIControl), lifted onto the touch pipeline. The
// press flips the core's onPressed layer (CreatorUI.setNodePressed: the `$pressed` cascade reaches
// the descendants), so the renderer has no pressed visual of its own. The touch sequence and the
// multitouch rule (TouchPipeline's header) are PressTracker's, shared with a paragraph's runs: every
// finger gets the sequence of its own, at its own point, except the click and the long press — the
// PRIMARY's, the finger that pressed the button while no other held it. A two-finger tap is ONE
// click; a second finger landing cancels a hold still pending (a pinch is not a hold) and arms none
// of its own, a hold that already fired keeps what it tracked. The press holds from the first
// finger down to the last one up; the click needs the finger inside the bounds.
//
// A pan the listener claimed (`ev.track({ claim })`) is refused to whoever else would take it —
// TouchClaims, asked by the recognizers themselves; the view holds no claim state. A button claims
// its own bounds for hit-testing (a UIControl's rule), unlike a container.
//
// Under a scroll view the press waits out the time UIKit used to hold the touch back for (PressTracker
// `touchPressDelay`); the scripted pointer has no scroll to wait for: it presses at once.
import LeCodesCore
import UIKit

final class ButtonView: NodeView, PointerTarget {
    private lazy var press = PressTracker(view: self, resolve: { [weak self] _ in self?.node },
                                          contains: { [weak self] _, p in
                                              guard let self else { return false }
                                              return self.bounds.contains(self.convert(p, from: UINode.appRoot ?? self))
                                          })
    var isPressedNow: Bool { press.isPressed }

    /// A button claims its own box (a UIControl's rule), on top of the widened children test.
    ///
    /// Over interactive glass (BoxPaint: the button's UIGlassEffect) a PASSIVE descendant hands the
    /// glass the touch. UIKit stops hit-testing at the topmost view: a text with nothing of its own
    /// under the finger, or an image, would take it and send it up the responder chain PAST the
    /// glass — the click still arrives, the press visual never shows (seen 2026-11-09 on the glass
    /// pill: a tap on its label did not stretch it). The glass is the button's own view, shows the
    /// press and the chain still carries the touch here. A descendant of a nested pointer target (a
    /// button in a button) stays that target's.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hit = super.hitTest(point, with: event) {
            if let glass = backdropView, glass.isUserInteractionEnabled, !hit.isDescendant(of: glass), isPassive(hit, at: point) { return glass }
            return hit
        }
        return !isHidden && alpha >= 0.01 && isUserInteractionEnabled && bounds.contains(point) ? self : nil
    }

    private func isPassive(_ hit: UIView, at point: CGPoint) -> Bool {
        var v = hit.superview
        while let cur = v, cur !== self {
            if cur is PointerTarget { return false }
            v = cur.superview
        }
        if hit is ImageView { return true }
        if let text = hit as? TextView { return !text.takesPress(at: convert(point, to: UINode.appRoot ?? window ?? self)) }
        return false
    }

    // MARK: - the pointer (UIKit's touches and the scripted pointer both land here)

    func pointerDown(_ pointerId: Int32, at p: CGPoint) { press.down(pointerId, at: p, pressAfter: 0) }
    func pointerMove(_ pointerId: Int32, to p: CGPoint) { press.move(pointerId, to: p) }
    func pointerUp(_ pointerId: Int32, at p: CGPoint) { press.up(pointerId, at: p) }
    func pointerCancel(_ pointerId: Int32) { press.cancel(pointerId) }

    // MARK: - UIKit's touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let delay = press.touchPressDelay
        for t in touches { press.down(TouchPipeline.pointerId(t), at: rootPoint(of: t), pressAfter: delay) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointerMove(TouchPipeline.pointerId(t), to: rootPoint(of: t)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointerUp(TouchPipeline.pointerId(t), at: rootPoint(of: t)) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointerCancel(TouchPipeline.pointerId(t)) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { press.viewLeftWindow() }   // the view can go away mid-hold
    }
}
