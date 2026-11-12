// The touch events of one interactive node to the runtime — the twin of renderers/android's
// TouchPipeline.kt + TouchHandlers.kt: touchStart, the tracked moves / end / cancel of a gesture a
// JS listener took (the runtime answers through HostUI.touchHandler, synchronously inside
// Core.touchStart on this host), the click, the long press. `node` 0 = not a touch target: nothing
// is sent. Coordinates are points in the app root's space (density 1: logical px).
//
// A pointer id is the UITouch's identity (its hash, truncated) — one live engine per process, so
// no scoping is needed. The long-press answer arrives through HostUI.longPressHandler inside
// Core.longPress, so `TouchHandlers.consumeLongPress` reads it right after the call.
//
// MULTITOUCH — one rule on every host (iOS, Android, desktop, web):
//  1. Every finger on an interactive node is its own pointer: a second finger landing on the node
//     gets its own touchStart (its own `ev.track`), its own moves, its own end / cancel, at its own
//     point — never the first finger's (NodeView sets isMultipleTouchEnabled; UIKit hands each
//     UITouch over separately).
//  2. The click is the PRIMARY's only: the first finger of the node's gesture, the one that pressed
//     the node while no other finger held it (PressTracker's `primary` — the one place that decides
//     it). It clicks lifting inside as before; the other fingers never click, so a two-finger tap is
//     ONE click (the browser's rule).
//  3. The long press is the primary's only: a second finger landing cancels a hold still pending (a
//     pinch is not a hold) and arms none of its own; a hold that already fired keeps what it tracked.
//  4. The press (`$pressed`, isButtonPressed) holds until the last finger lifts.
// PressTracker applies it, for a button (ButtonView: its own node) and a paragraph (TextView: the
// inline run under the finger, docs/plans/rich-text-plan.md rule 5); a screen has no click and no
// long press, so it only ever needs rule 1.
//
// WHO GETS A PAN (`ev.track({ claim })`) is decided in ONE place, TouchClaims, and asked by every
// recognizer of the renderer and the host that could take a pan away from a listener: the scroll
// views (the scrollable, the vlist, the pager — TouchScrollView), the sheet's pan, the host's edge
// swipe. The question is asked when such a recognizer is about to BEGIN, about the pan IT measured:
// a track whose claim mask covers that direction, on a node inside the recognizer's view, refuses
// it for the rest of the gesture (a refused recognizer fails). Nothing is latched from the moves a
// view was delivered — a recognizer sees every move BEFORE the view does, so a flag set by the
// view's moves lost the race whenever one move carried the finger past the recognizer's threshold.
// What this needs of UIKit is that the track exists by then: a scroll view of the renderer hands
// its content the touch at once (TouchScrollView), so the listener has answered touchStart — with
// its claim — before any pan can begin.
import LeCodesCore
import UIKit

public struct TouchTrack {
    public let node: Int
    public let hasMove: Bool
    /// The PanDirection mask the listener claimed: a pan that way is the listener's (TouchClaims).
    public let claim: UInt8
}

/// PanDirection of creator-pkg.h, the low byte of a track answer (`sdk/src/ui/tree.ts` PAN): one
/// bit per direction the finger travels, y growing downward. `pan-x` = left | right, `pan-y` =
/// up | down, `claim: true` = all four.
public enum PanDirection {
    public static let none: UInt8 = 0
    public static let up: UInt8 = 1 << 0
    public static let right: UInt8 = 1 << 1
    public static let down: UInt8 = 1 << 2
    public static let left: UInt8 = 1 << 3
    public static let horizontal: UInt8 = left | right
    public static let vertical: UInt8 = up | down
    public static let all: UInt8 = up | right | down | left

    /// The direction of a pan: its dominant axis, a tie is vertical (Android's checkClaim); no
    /// travel has none.
    public static func of(_ dx: CGFloat, _ dy: CGFloat) -> UInt8 {
        if dx == 0, dy == 0 { return none }
        if abs(dx) > abs(dy) { return dx > 0 ? right : left }
        return dy > 0 ? down : up
    }
}

public enum TouchClaims {
    /// A pan recognizer is about to begin: does a listener's claim take this pan from it? The
    /// direction is the recognizer's own reading (its velocity when it has no translation yet).
    public static func blocks(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let owner = pan.view else { return false }
        var by = pan.translation(in: owner)
        if by == .zero { by = pan.velocity(in: owner) }
        return blocks(panBy: by, in: owner)
    }

    /// A pan by `by` that a recognizer on `owner` would take: refused when a live track claims
    /// that direction on a node inside `owner`.
    public static func blocks(panBy by: CGPoint, in owner: UIView) -> Bool {
        let direction = PanDirection.of(by.x, by.y)
        guard direction != PanDirection.none else { return false }
        return TouchHandlers.claims.contains { track in
            guard track.claim & direction != 0, let node = Nodes[track.node], !node.isRemoved else { return false }
            return node.boxNode.view.isDescendant(of: owner)   // a run's view is its paragraph's
        }
    }
}

public enum TouchHandlers {
    private static var tracks: [Int32: TouchTrack] = [:]
    private static var longPressed = Set<Int32>()

    /// HostUI.touchHandler: a JS listener took this pointer's gesture.
    public static func add(_ pointerId: Int32, hasMove: Bool, claim: UInt8, node: Int) {
        tracks[pointerId] = TouchTrack(node: node, hasMove: hasMove, claim: claim)
    }
    public static func get(_ pointerId: Int32) -> TouchTrack? { tracks[pointerId] }
    public static func remove(_ pointerId: Int32) { tracks[pointerId] = nil }
    /// The live tracks that claim a pan (TouchClaims).
    static var claims: [TouchTrack] { tracks.values.filter { $0.claim != 0 } }

    /// HostUI.longPressHandler: a listener handled the press — swallow the click that would follow.
    public static func markLongPress(_ pointerId: Int32) { longPressed.insert(pointerId) }
    /// Removes and returns the flag: once per press, on release AND on the press starting, so a
    /// stale flag can never leak into the next press.
    public static func consumeLongPress(_ pointerId: Int32) -> Bool { longPressed.remove(pointerId) != nil }

    public static func clear() {
        tracks.removeAll()
        longPressed.removeAll()
    }
}

public struct TouchPosition {
    public let startX: CGFloat, startY: CGFloat
    public var lastX: CGFloat, lastY: CGFloat
}

public enum TouchPipeline {
    /// A touch began on `node` (0 = nothing sent): the runtime answers through touchHandler when a
    /// listener took the gesture.
    @discardableResult
    public static func start(node: Int, pointerId: Int32, at p: CGPoint, touches: inout [Int32: TouchPosition]) -> Bool {
        guard node != 0 else { return false }
        Core.touchStart(node, pointerId: pointerId, x: Float(p.x), y: Float(p.y))
        touches[pointerId] = TouchPosition(startX: p.x, startY: p.y, lastX: p.x, lastY: p.y)
        return true
    }

    /// Held past the threshold without sliding away. JS decides whether it counts, and reports
    /// back through longPressHandler (read with TouchHandlers.consumeLongPress).
    @discardableResult
    public static func longPress(node: Int, pointerId: Int32, at p: CGPoint) -> Bool {
        guard node != 0 else { return false }
        Core.longPress(node, pointerId: pointerId, x: Float(p.x), y: Float(p.y))
        return true
    }

    /// A move of a tracked pointer.
    @discardableResult
    public static func move(node: Int, pointerId: Int32, to p: CGPoint, touches: inout [Int32: TouchPosition]) -> Bool {
        guard node != 0, let track = TouchHandlers.get(pointerId), track.node == node else { return false }
        guard track.hasMove || track.claim != 0, var t = touches[pointerId] else { return true }
        let dx = p.x - t.lastX, dy = p.y - t.lastY
        Core.touchMove(pointerId: pointerId, x: Float(p.x), y: Float(p.y), deltaX: Float(dx), deltaY: Float(dy))
        t.lastX = p.x
        t.lastY = p.y
        touches[pointerId] = t
        return true
    }

    /// The pointer lifted: the track closes (only if it existed), the click is INDEPENDENT of it.
    public static func end(node: Int, pointerId: Int32, at p: CGPoint, touches: inout [Int32: TouchPosition], sendClick: Bool) {
        let t = touches.removeValue(forKey: pointerId)
        if let track = TouchHandlers.get(pointerId), track.node == node, node != 0 {
            TouchHandlers.remove(pointerId)
            let dx = t.map { p.x - $0.lastX } ?? 0, dy = t.map { p.y - $0.lastY } ?? 0
            Core.touchEnd(pointerId: pointerId, x: Float(p.x), y: Float(p.y), deltaX: Float(dx), deltaY: Float(dy))
        }
        if sendClick, node != 0 {
            Core.touchClick(node, pointerId: pointerId, x: Float(p.x), y: Float(p.y))
        }
    }

    public static func cancel(node: Int, pointerId: Int32, touches: inout [Int32: TouchPosition]) {
        touches.removeValue(forKey: pointerId)
        if let track = TouchHandlers.get(pointerId), track.node == node {
            TouchHandlers.remove(pointerId)
            if node != 0 { Core.touchCancel(pointerId: pointerId) }
        }
    }

    /// The pointer id of a UITouch: its identity, one live engine per process.
    public static func pointerId(_ touch: UITouch) -> Int32 { Int32(truncatingIfNeeded: ObjectIdentifier(touch).hashValue) }
}

/// A view that takes pointers: UIKit's touches and the scripted pointer of a check runner reach it
/// through the same four calls (points in the app root's space) — the check runner injects no
/// UITouch, it calls these after the root's hit-test.
public protocol PointerTarget: AnyObject {
    func pointerDown(_ pointerId: Int32, at rootPoint: CGPoint)
    func pointerMove(_ pointerId: Int32, to rootPoint: CGPoint)
    func pointerUp(_ pointerId: Int32, at rootPoint: CGPoint)
    func pointerCancel(_ pointerId: Int32)
}

extension UIView {
    /// The point of a touch in the app root's space (the window's when no root is set).
    func rootPoint(of touch: UITouch) -> CGPoint { touch.location(in: UINode.appRoot ?? window ?? self) }
}

/// The press of one touch target — the multitouch rule above, in ONE place: a button (ButtonView: its
/// own node, its own box) and a paragraph (TextView: the inline run under the finger, else the
/// paragraph). The node a gesture presses is chosen when its primary lands (`resolve`); every finger
/// after it joins that gesture until the last one lifts. The press flips the core's onPressed layer
/// (CreatorUI.setNodePressed: the `$pressed` cascade); the touch sequence: down → Core.touchStart (a
/// listener may take the gesture) + the long-press timer (0.5 s, 10 pt tolerance), moves → the
/// tracked moves, up → touchEnd and the click if the finger is still on the node (`contains`) and no
/// long press fired, cancel → touchCancel.
///
/// Under a scroll view the touch arrives at once (TouchScrollView: a listener has to answer
/// touchStart before the scroll's pan can begin), so the PRESS waits out the time UIKit used to hold
/// the touch back for: a scroll that starts on the target cancels it before `$pressed` ever shows,
/// and a tap shorter than the wait shows none. The scripted pointer has no scroll to wait for.
final class PressTracker {
    private unowned let view: UIView
    /// The node a finger landing at a root point presses; nil = nothing there is the view's.
    private let resolve: (CGPoint) -> UINode?
    /// Is a root point still on the gesture's node (the click lifts inside)?
    private let contains: (UINode, CGPoint) -> Bool
    /// The gesture's node, chosen by its primary.
    private(set) weak var node: UINode?
    private var touches: [Int32: TouchPosition] = [:]
    private var pointers: [Int32: CGPoint] = [:]   // the last root point per live pointer
    /// The primary finger: nil while no finger holds the target, and from the moment the primary
    /// lifts (a UITouch's id can come back for the next finger, which must not inherit the click).
    private var primary: Int32?
    private var didLongPress = false
    private var longPressWork: DispatchWorkItem?
    private var longPressStart: CGPoint = .zero
    private var pressWork: DispatchWorkItem?
    private(set) var isPressed = false
    static let longPressDelay: TimeInterval = 0.5
    static let longPressMoveTolerance: CGFloat = 10
    /// UIScrollView's own hold of a content touch (delaysContentTouches), now the press's.
    static let scrollPressDelay: TimeInterval = 0.15

    init(view: UIView, resolve: @escaping (CGPoint) -> UINode?, contains: @escaping (UINode, CGPoint) -> Bool) {
        self.view = view
        self.resolve = resolve
        self.contains = contains
    }

    private var touchNode: Int { node.map { $0.has(TreeEvents.TREE_FLAG_INTERACTIVE) ? $0.id : 0 } ?? 0 }
    private var longPressNode: Int { node.map { $0.has(TreeEvents.TREE_FLAG_LONG_PRESS) ? $0.id : 0 } ?? 0 }

    /// Holds this pointer (a down it took, not yet up or cancelled).
    func holds(_ pointerId: Int32) -> Bool { pointers[pointerId] != nil }

    /// A finger landed: false = nothing under it is this target's (no gesture to join, nothing
    /// `resolve` names) — the caller hands the pointer on.
    @discardableResult
    func down(_ pointerId: Int32, at p: CGPoint, pressAfter delay: TimeInterval) -> Bool {
        let isPrimary = pointers.isEmpty   // no other finger holds the target
        if isPrimary { node = resolve(p) }
        guard let node, !node.isRemoved else { return false }
        pointers[pointerId] = p
        _ = TouchHandlers.consumeLongPress(pointerId)   // a stale flag must not swallow this press's click
        if isPrimary {
            primary = pointerId
            didLongPress = false
            armPress(after: delay)
        } else {
            cancelLongPress()   // a pinch is not a hold
        }
        TouchPipeline.start(node: touchNode, pointerId: pointerId, at: p, touches: &touches)
        if isPrimary { armLongPress(pointerId, at: p) }
        return true
    }

    func move(_ pointerId: Int32, to p: CGPoint) {
        guard let node, !node.isRemoved else { return }
        pointers[pointerId] = p
        if pointerId == primary, longPressWork != nil, hypot(p.x - longPressStart.x, p.y - longPressStart.y) > PressTracker.longPressMoveTolerance { cancelLongPress() }
        TouchPipeline.move(node: touchNode, pointerId: pointerId, to: p, touches: &touches)
    }

    func up(_ pointerId: Int32, at p: CGPoint) {
        pointers[pointerId] = nil
        let isPrimary = pointerId == primary
        if isPrimary { primary = nil }
        cancelLongPress()
        let longPressed = TouchHandlers.consumeLongPress(pointerId) || (isPrimary && didLongPress)
        let inside = node.map { contains($0, p) } ?? false
        let sendClick = isPrimary && !longPressed && inside && (node?.has(TreeEvents.TREE_FLAG_CLICK) ?? false)
        TouchPipeline.end(node: touchNode, pointerId: pointerId, at: p, touches: &touches, sendClick: sendClick)
        if pointers.isEmpty { release() }
    }

    func cancel(_ pointerId: Int32) {
        pointers[pointerId] = nil
        if pointerId == primary { primary = nil }
        cancelLongPress()
        _ = TouchHandlers.consumeLongPress(pointerId)
        TouchPipeline.cancel(node: touchNode, pointerId: pointerId, touches: &touches)
        if pointers.isEmpty { release() }
    }

    /// The view left the window mid-hold: nothing may fire later.
    func viewLeftWindow() {
        cancelLongPress()
        pressWork?.cancel()
        pressWork = nil
    }

    /// The press delay a UIKit touch takes here: a scroll view above may still take it.
    var touchPressDelay: TimeInterval { isUnderLiveScroll ? PressTracker.scrollPressDelay : 0 }

    // MARK: - the press

    private func armPress(after delay: TimeInterval) {
        pressWork?.cancel()
        pressWork = nil
        guard delay > 0, !isPressed else { setPressed(true); return }
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
        primary = nil
        pressWork?.cancel()
        pressWork = nil
        setPressed(false)
    }

    private func setPressed(_ pressed: Bool) {
        guard isPressed != pressed, let node, !node.isRemoved else { return }
        isPressed = pressed
        CreatorUI.setNodePressed(node.id, pressed)
    }

    /// A scroll view above that has somewhere to go: it may still take this touch.
    private var isUnderLiveScroll: Bool {
        var v = view.superview
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
            guard let self, let node = self.node, !node.isRemoved, self.primary == pointerId, self.pointers[pointerId] != nil else { return }
            self.longPressWork = nil
            TouchPipeline.longPress(node: self.longPressNode, pointerId: pointerId, at: p)
            if TouchHandlers.consumeLongPress(pointerId) { self.didLongPress = true }
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PressTracker.longPressDelay, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }
}
