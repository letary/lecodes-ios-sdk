// The button's view — the old host's NodeButton (a UIControl), lifted onto the touch pipeline. The
// press flips the core's onPressed layer (CreatorUI.setNodePressed: the `$pressed` cascade reaches
// the descendants), so the renderer has no pressed visual of its own. The touch sequence: began →
// Core.touchStart (a listener may take the gesture) + the long-press timer (0.5 s, 10 pt tolerance),
// moved → the tracked moves, ended → touchEnd and the click if the finger is still inside the bounds
// and no long press fired, cancelled → touchCancel. A pan the listener claimed (`ev.track({ claim })`)
// is refused to whoever else would take it — TouchClaims, asked by the recognizers themselves; the
// view holds no claim state. A button claims its own bounds for hit-testing (a UIControl's rule),
// unlike a container.
//
// Under a scroll view the touch arrives at once (TouchScrollView: a listener has to answer
// touchStart before the scroll's pan can begin), so the PRESS waits out the time UIKit used to hold
// the touch back for: a scroll that starts on a button cancels it before `$pressed` ever shows, and
// a tap shorter than the wait shows none — what both looked like when the scroll view delayed the
// touch itself. The scripted pointer has no scroll to wait for: it presses at once.
import LeCodesCore
import UIKit

final class ButtonView: NodeView, PointerTarget {
    private var button: UINodeButton? { node as? UINodeButton }
    private var touches: [Int32: TouchPosition] = [:]
    private var pointers: [Int32: CGPoint] = [:]   // the last root point per live pointer
    private var didLongPress = false
    private var longPressWork: DispatchWorkItem?
    private var longPressStart: CGPoint = .zero
    private var pressWork: DispatchWorkItem?
    private(set) var isPressedNow = false
    static let longPressDelay: TimeInterval = 0.5
    static let longPressMoveTolerance: CGFloat = 10
    /// UIScrollView's own hold of a content touch (delaysContentTouches), now the press's.
    static let scrollPressDelay: TimeInterval = 0.15

    /// A button claims its own box (a UIControl's rule), on top of the widened children test.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hit = super.hitTest(point, with: event) { return hit }
        return !isHidden && alpha >= 0.01 && isUserInteractionEnabled && bounds.contains(point) ? self : nil
    }

    private var touchNode: Int { node.map { $0.has(TreeEvents.TREE_FLAG_INTERACTIVE) ? $0.id : 0 } ?? 0 }
    private var longPressNode: Int { node.map { $0.has(TreeEvents.TREE_FLAG_LONG_PRESS) ? $0.id : 0 } ?? 0 }

    // MARK: - the pointer (UIKit's touches and the scripted pointer both land here)

    func pointerDown(_ pointerId: Int32, at p: CGPoint) { pointerDown(pointerId, at: p, pressAfter: 0) }

    private func pointerDown(_ pointerId: Int32, at p: CGPoint, pressAfter delay: TimeInterval) {
        guard let node, !node.isRemoved else { return }
        pointers[pointerId] = p
        _ = TouchHandlers.consumeLongPress(pointerId)   // a stale flag must not swallow this press's click
        didLongPress = false
        armPress(after: delay)
        TouchPipeline.start(node: touchNode, pointerId: pointerId, at: p, touches: &touches)
        armLongPress(pointerId, at: p)
    }

    func pointerMove(_ pointerId: Int32, to p: CGPoint) {
        guard let node, !node.isRemoved else { return }
        pointers[pointerId] = p
        if longPressWork != nil, hypot(p.x - longPressStart.x, p.y - longPressStart.y) > ButtonView.longPressMoveTolerance { cancelLongPress() }
        TouchPipeline.move(node: touchNode, pointerId: pointerId, to: p, touches: &touches)
    }

    func pointerUp(_ pointerId: Int32, at p: CGPoint) {
        pointers[pointerId] = nil
        cancelLongPress()
        let longPressed = TouchHandlers.consumeLongPress(pointerId) || didLongPress
        let inside = bounds.contains(convert(p, from: UINode.appRoot ?? self))
        let sendClick = !longPressed && inside && (node?.has(TreeEvents.TREE_FLAG_CLICK) ?? false)
        TouchPipeline.end(node: touchNode, pointerId: pointerId, at: p, touches: &touches, sendClick: sendClick)
        if pointers.isEmpty { release() }
    }

    func pointerCancel(_ pointerId: Int32) {
        pointers[pointerId] = nil
        cancelLongPress()
        _ = TouchHandlers.consumeLongPress(pointerId)
        TouchPipeline.cancel(node: touchNode, pointerId: pointerId, touches: &touches)
        if pointers.isEmpty { release() }
    }

    // MARK: - the press

    private func armPress(after delay: TimeInterval) {
        pressWork?.cancel()
        pressWork = nil
        guard delay > 0, !isPressedNow else { setPressed(true); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointers.isEmpty else { return }
            self.pressWork = nil
            self.setPressed(true)
        }
        pressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The last pointer left: a press still waiting never shows.
    private func release() {
        pressWork?.cancel()
        pressWork = nil
        setPressed(false)
    }

    private func setPressed(_ pressed: Bool) {
        guard isPressedNow != pressed, let node, !node.isRemoved else { return }
        isPressedNow = pressed
        CreatorUI.setNodePressed(node.id, pressed)
    }

    /// A scroll view above that has somewhere to go: it may still take this touch.
    private var isUnderLiveScroll: Bool {
        var v = superview
        while let cur = v {
            if let scroll = cur as? UIScrollView, scroll.isScrollEnabled {
                let overflows = scroll.contentSize.width > scroll.bounds.width + 0.5 || scroll.contentSize.height > scroll.bounds.height + 0.5
                if overflows || scroll.alwaysBounceVertical || scroll.alwaysBounceHorizontal { return true }
            }
            v = cur.superview
        }
        return false
    }

    // MARK: - the long press

    private func armLongPress(_ pointerId: Int32, at p: CGPoint) {
        cancelLongPress()
        guard longPressNode != 0 else { return }
        longPressStart = p
        let work = DispatchWorkItem { [weak self] in
            guard let self, let node = self.node, !node.isRemoved, self.pointers[pointerId] != nil else { return }
            self.longPressWork = nil
            TouchPipeline.longPress(node: self.longPressNode, pointerId: pointerId, at: p)
            if TouchHandlers.consumeLongPress(pointerId) { self.didLongPress = true }
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ButtonView.longPressDelay, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    // MARK: - UIKit's touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let delay = isUnderLiveScroll ? ButtonView.scrollPressDelay : 0
        for t in touches { pointerDown(TouchPipeline.pointerId(t), at: rootPoint(of: t), pressAfter: delay) }
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
        if window == nil {   // the view can go away mid-hold
            cancelLongPress()
            pressWork?.cancel()
            pressWork = nil
        }
    }
}
