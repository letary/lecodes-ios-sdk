// A widget's view and its scrim. A widget never clips, and its absolutely-positioned children sit
// outside its auto-sized frame (a root `top:0,left:0,right:0` gets its content height while a
// button sits at 40vmin), so the widened hit-test of NodeView applies; a sheet, or an interactive
// widget (onTouchStart), claims its own background — the drag surface must be grabbable anywhere
// on the sheet, and a solid sheet swallowing taps is the dismissal doctrine. The scrim is a
// sibling directly behind the widget: an interactive view that intercepts every touch in its
// bounds (the screen behind never sees them); a tap fires TREE_EVENT_OVERLAY_TAP, gated on the
// flag and posted — outside the gesture transaction, the codebase's JS rule.
import LeCodesCore
import UIKit

final class WidgetView: ScreenView {
    private var widget: UINodeWidget? { node as? UINodeWidget }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hit = super.hitTest(point, with: event) { return hit }
        let claims = widget?.sheet != nil
        return claims && bounds.contains(point) && !isHidden && alpha >= 0.01 && isUserInteractionEnabled ? self : nil
    }
}

public final class WidgetOverlayView: UIView, PointerTarget {
    private weak var widget: UINodeWidget?
    private var downInside = false

    init(widget: UINodeWidget) {
        self.widget = widget
        super.init(frame: .zero)
        isUserInteractionEnabled = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    private func fireTap() {
        guard let widget, !widget.isRemoved, widget.has(TreeEvents.TREE_FLAG_OVERLAY_TAP) else { return }
        let id = widget.id
        JSThread.post { Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_OVERLAY_TAP) }
    }

    public func pointerDown(_ pointerId: Int32, at rootPoint: CGPoint) { downInside = true }
    public func pointerMove(_ pointerId: Int32, to rootPoint: CGPoint) {}
    public func pointerUp(_ pointerId: Int32, at rootPoint: CGPoint) {
        let inside = bounds.contains(convert(rootPoint, from: UINode.appRoot ?? self))
        if downInside, inside { fireTap() }
        downInside = false
    }
    public func pointerCancel(_ pointerId: Int32) { downInside = false }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointerDown(TouchPipeline.pointerId(t), at: rootPoint(of: t)) }
    }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointerUp(TouchPipeline.pointerId(t), at: rootPoint(of: t)) }
    }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointerCancel(TouchPipeline.pointerId(t)) }
    }
}

/// A vertical scrollable the sheet coordinates with (the scroll view of the scrollable step).
public protocol SheetScrollable: UIScrollView {
    var hasScroll: Bool { get }
    /// While the sheet owns the drag the inner scroll's own pan keeps running (simultaneous
    /// recognition), so every offset change it produces is snapped back to this.
    var sheetPinnedOffsetY: CGFloat? { get set }
}

/// The bottom sheet — the old host's WidgetSheetBehavior, lifted: the detents, the pan gesture,
/// the snap physics and the inner-scroll handoff of a widget carrying `sheetDetents`. Detents are
/// ascending fractions of the host height; the widget's yoga box is the HIGHEST detent (the SDK
/// sets `height: max%` + `bottom: 0`) and detent d shows the top d·H by translating the view down
/// by (max − d)·H — a pure transform, never a relayout. TREE_EVENT_DETENT fires ONLY for gesture
/// settles (a programmatic `sheetDetent` is echoed SDK-side); -1 = dragged below the lowest detent
/// while dismissible (the SDK answers with hide()). The same model as Android's, for the same
/// reasons: a sheet is anchored to the BOTTOM edge, so there is a hard stop at the top detent —
/// lifting it would open a bare strip underneath (neither UISheetPresentationController nor
/// Android's BottomSheetBehavior lets you drag past the expanded state).
public final class WidgetSheetBehavior: NSObject, UIGestureRecognizerDelegate {
    private unowned let widget: UINodeWidget
    private var view: UIView { widget.view }

    public var detents: [CGFloat] = [0.5]
    public var dismissible = true
    /// The target detent; -1 = off screen (pre-entrance / exiting).
    private var targetIndex = 0
    /// The last GESTURE-settled index — the detent event's dedupe baseline.
    private var settledIndex = 0
    /// The current translateY from the yoga base frame.
    public private(set) var currentOffset: CGFloat = 0
    private var entrancePlayed = false
    private let pan = UIPanGestureRecognizer()

    init(widget: UINodeWidget) {
        self.widget = widget
        super.init()
        pan.addTarget(self, action: #selector(handlePan))
        pan.delegate = self
        widget.view.addGestureRecognizer(pan)
    }

    // MARK: - geometry

    private var hostHeight: CGFloat { view.superview?.bounds.height ?? 0 }
    /// The whole sheet below the screen edge.
    private var hiddenOffset: CGFloat { view.bounds.height }

    public func offset(forDetent index: Int) -> CGFloat {
        guard index >= 0, !detents.isEmpty else { return hiddenOffset }
        let i = min(max(index, 0), detents.count - 1)
        return (detents[detents.count - 1] - detents[i]) * hostHeight
    }

    private func applyOffset(_ offset: CGFloat) {
        currentOffset = offset
        widget.box.offsetY = offset
    }

    private func animate(to target: CGFloat, damping: CGFloat, velocity: CGFloat = 0, beginFromCurrent: Bool = true) {
        guard Animations.enabled else { applyOffset(target); return }
        var options: UIView.AnimationOptions = [.allowUserInteraction]
        if beginFromCurrent { options.insert(.beginFromCurrentState) }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: damping, initialSpringVelocity: velocity, options: options) {
            self.applyOffset(target)
        }
    }

    /// After the base frame landed: re-compose the offset; the first valid layout plays the entrance.
    func layoutDidApply() {
        guard hostHeight > 0, view.bounds.height > 0 else { applyOffset(currentOffset); return }
        if entrancePlayed { applyOffset(currentOffset); return }
        entrancePlayed = true
        applyOffset(hiddenOffset)
        guard targetIndex >= 0 else { return }
        settledIndex = targetIndex
        // The target is read when the entrance RUNS: a `sheetDetent` written after `sheetDetents`
        // in the same record moves it before the post lands.
        JSThread.post { [weak self] in
            guard let self, self.targetIndex >= 0 else { return }
            self.animate(to: self.offset(forDetent: self.targetIndex), damping: 0.9, beginFromCurrent: false)
        }
    }

    /// The programmatic target (`sheetDetent`). Never fires the detent event.
    public func setDetent(_ index: Int, animated: Bool) {
        targetIndex = index >= 0 ? min(max(index, 0), detents.count - 1) : -1
        if targetIndex >= 0 { settledIndex = targetIndex }
        guard entrancePlayed, hostHeight > 0 else { return }   // the entrance lands on the target
        let target = offset(forDetent: targetIndex)
        if animated { animate(to: target, damping: 0.9) } else { applyOffset(target) }
    }

    // MARK: - the pan + the inner-scroll handoff

    private var dragStartOffset: CGFloat = 0
    private var activeScroll: SheetScrollable?
    private var sheetOwnsDrag = true

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let host = view.superview else { return }
        switch gesture.state {
        case .began:
            dragStartOffset = currentOffset
            activeScroll = findScrollable(under: gesture.location(in: view))
            // At the top detent an inner scrollable owns the drag (scroll first); lower, the sheet
            // owns it and the scroll is pinned in place.
            if let scroll = activeScroll, scroll.hasScroll, currentOffset <= 0.5 {
                sheetOwnsDrag = false
            } else {
                sheetOwnsDrag = true
                pinScroll()
            }
        case .changed:
            let translation = gesture.translation(in: host).y
            if !sheetOwnsDrag {
                // The transfer moment: the content reaches its top while the finger moves down.
                if let scroll = activeScroll, scroll.contentOffset.y <= 0.5, gesture.velocity(in: host).y > 0 {
                    sheetOwnsDrag = true
                    gesture.setTranslation(.zero, in: host)
                    dragStartOffset = currentOffset
                    pinScroll()
                }
                return
            }
            var next = dragStartOffset + translation
            // Hand BACK to the scroll when pushing above the top detent with scrollable content.
            if next < 0, let scroll = activeScroll, scroll.hasScroll {
                sheetOwnsDrag = false
                unpinScroll()
                applyOffset(0)
                gesture.setTranslation(.zero, in: host)
                dragStartOffset = 0
                return
            }
            // The hard stop at the top detent — no rubber-band. `next` is clamped, not the
            // accumulator, so dragging back down tracks the finger 1:1 with no drift.
            if next < 0 { next = 0 }
            let lowest = offset(forDetent: 0)
            if next > lowest, !dismissible { next = lowest + (next - lowest) / 3 }   // resistance below the lowest detent
            applyOffset(next)
        case .ended, .cancelled:
            let wasSheet = sheetOwnsDrag
            unpinScroll()
            activeScroll = nil
            if wasSheet { settle(velocityY: gesture.velocity(in: host).y) }
        default:
            break
        }
    }

    /// The release: the nearest detent to the projected offset, or the dismissal — past the
    /// midpoint between the lowest detent and gone, or a hard downward fling at / below it.
    func settle(velocityY: CGFloat) {
        let projected = currentOffset + 0.15 * velocityY
        let lowest = offset(forDetent: 0)
        if dismissible, projected > (lowest + hiddenOffset) / 2 || (velocityY > 1500 && currentOffset >= lowest - 0.5) {
            targetIndex = -1
            animateSettle(to: hiddenOffset, velocityY: velocityY)
            fireDetent(-1)
            return
        }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 0..<detents.count {
            let d = abs(offset(forDetent: i) - projected)
            if d < bestDistance { bestDistance = d; best = i }
        }
        targetIndex = best
        animateSettle(to: offset(forDetent: best), velocityY: velocityY)
        if best != settledIndex {
            settledIndex = best
            fireDetent(best)
        }
    }

    private func animateSettle(to target: CGFloat, velocityY: CGFloat) {
        let distance = abs(target - currentOffset)
        let springVelocity = distance > 0 ? min(abs(velocityY) / distance, 8) : 0
        animate(to: target, damping: 0.85, velocity: springVelocity)
    }

    /// Gesture settles only, posted — outside the gesture transaction.
    private func fireDetent(_ index: Int) {
        guard widget.has(TreeEvents.TREE_FLAG_DETENT), !widget.isRemoved else { return }
        let id = widget.id
        JSThread.post { Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_DETENT, [.int(Int32(index))]) }
    }

    /// A scripted drag (a test): the offset moved by `dy` from the current one, then the release.
    public func scriptedDrag(dy: CGFloat, velocityY: CGFloat) {
        var next = currentOffset + dy
        if next < 0 { next = 0 }
        let lowest = offset(forDetent: 0)
        if next > lowest, !dismissible { next = lowest + (next - lowest) / 3 }
        applyOffset(next)
        settle(velocityY: velocityY)
    }

    // MARK: - scroll coordination

    /// The vertical scrollable under the touch — per gesture, never cached (a sheet can hold a
    /// pager with a list per page).
    private func findScrollable(under point: CGPoint) -> SheetScrollable? {
        var v = view.hitTest(point, with: nil)
        while let cur = v, cur !== view {
            if let s = cur as? SheetScrollable { return s }
            v = cur.superview
        }
        return nil
    }
    private func pinScroll() {
        guard let s = activeScroll else { return }
        s.sheetPinnedOffsetY = max(s.contentOffset.y, 0)
    }
    private func unpinScroll() { activeScroll?.sheetPinnedOffsetY = nil }

    // MARK: - UIGestureRecognizerDelegate

    /// Alongside the inner scroll's own pan — ownership is decided per move above.
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView
    }
    /// Horizontal swipes (a pager inside the sheet) pass through untouched, and so does a pan a
    /// listener inside the sheet claimed.
    public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        let v = pan.velocity(in: view)
        return abs(v.y) > abs(v.x) && !TouchClaims.blocks(g)
    }
}
