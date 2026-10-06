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
            return node.view.isDescendant(of: owner)
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
