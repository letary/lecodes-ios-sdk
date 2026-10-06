// The scrollable's view — the old host's NodeScrollable (a UIScrollView), lifted onto the
// contract: the content extent from the core (getContentHeight / Width) after every layout visit,
// the scroll events by id gated on the flag mask (SCROLL as Core.nodeScroll, OVERSCROLL and
// SCROLL_RELEASE as node events), the overscroll modes (bounce / absorb / none), the snap paging
// with its two regimes, pull-to-refresh through UIRefreshControl and Core.refresh, the keyboard
// dismissal mode, the sheet's pin. A scrollable that has nothing to scroll and no refresh lets
// touches fall through (it would otherwise swallow every tap on its area).
import LeCodesCore
import UIKit

public enum ScrollAxis { case vertical, horizontal, both }
public enum OverscrollMode { case bounce, absorb, none }
enum SnapAlign { case none, start, center, end }

/// What every scroll view of the renderer (the scrollable, the vlist, the pager) does with a touch.
/// Its content gets the touch AT ONCE: UIKit's default holds it back for 150 ms and, when the pan
/// begins inside that window, never delivers it — a listener that claims the pan (`ev.track({ claim
/// })`) was never asked, so a drag that started moving at once always went to the scroll (and one
/// across the scroll's axis, which its pan never takes, always to the listener). With the touch
/// delivered the track exists when the pan wants to begin, and TouchClaims answers for it; a pan
/// nobody claimed begins as ever and the content's touch is cancelled — an input's too (UIKit keeps
/// a UIControl's touch: a drag that starts on a field would never scroll).
class TouchScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        delaysContentTouches = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is InputControl ? true : super.touchesShouldCancel(in: view)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer, TouchClaims.blocks(g) { return false }
        return super.gestureRecognizerShouldBegin(g)
    }
}

class ScrollContainerView: TouchScrollView, UIScrollViewDelegate, SheetScrollable {
    weak var node: UINodeScrollable?
    var axis: ScrollAxis = .vertical { didSet { updateContentSize() } }
    var overscrollMode: OverscrollMode = .bounce {
        didSet {
            bounces = overscrollMode != .none
            if overscrollMode == .bounce { overscrollValue = 0 } else { scrollViewDidScroll(self) }
        }
    }
    var snapAlign: SnapAlign = .none {
        didSet { decelerationRate = snapAlign == .none ? .normal : .fast }   // .fast = the standard approximation of the paging feel
    }
    /// Above this |velocity| (points per ms) a release is a flick, not a carry-and-drop.
    static let snapFlickVelocity: CGFloat = 0.2
    private var snapDragStartOffset: CGFloat = 0
    private var overscrollValue: CGFloat = 0
    private(set) var isTouched = false
    private var tempDisableBounce = false

    init(node: UINodeScrollable) {
        self.node = node
        super.init(frame: .zero)
        contentInsetAdjustmentBehavior = .never
        keyboardDismissMode = .interactive
        delegate = self
        clipsToBounds = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    // MARK: - SheetScrollable

    var hasScroll: Bool {
        axis == .horizontal ? contentSize.width > bounds.width + 0.5 : contentSize.height > bounds.height + 0.5
    }
    var sheetPinnedOffsetY: CGFloat?

    // MARK: - the box

    override func layoutSubviews() {
        super.layoutSubviews()
        node?.box.layoutSublayers()
        updateRefreshControlOffset()
    }

    /// After a layout visit: the content extent the core computed.
    func updateContentSize() {
        guard let node else { return }
        let w = bounds.width, h = bounds.height
        var size = CGSize(width: w, height: h)
        if axis != .horizontal {
            let ch = CGFloat(CreatorUI.contentHeight(node.id))
            if ch.isFinite { size.height = ch }
        }
        if axis != .vertical {
            let cw = CGFloat(CreatorUI.contentWidth(node.id))
            if cw.isFinite { size.width = cw }
        }
        if size != contentSize { contentSize = size }
    }

    /// Nothing to scroll and no refresh: the view lets touches through to what is behind it.
    private var passesTouchesThrough: Bool { !hasScroll && refreshControl == nil }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self, passesTouchesThrough { return nil }
        return hit
    }

    // MARK: - the events

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let pinned = sheetPinnedOffsetY {
            if scrollView.contentOffset.y != pinned { scrollView.setContentOffset(CGPoint(x: 0, y: pinned), animated: false) }
            return
        }
        guard let node, !node.isRemoved else { return }
        // A horizontal scrollable reports its own axis — contentOffset.y is pinned at 0 there, and
        // the overscroll bookkeeping below is vertical only by construction.
        if axis == .horizontal {
            node.onScroll(scrollView.contentOffset.x)
            return
        }
        let y = scrollView.contentOffset.y
        if y < 0 {
            if isTouched {
                if overscrollMode == .bounce {
                    node.onOverscroll(y)
                } else {
                    overscrollValue += y
                    node.onOverscroll(overscrollValue)
                    scrollView.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
                }
            } else if tempDisableBounce || overscrollMode != .bounce {
                scrollView.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
            }
        } else if overscrollValue < 0, isTouched {
            overscrollValue = min(overscrollValue + y, 0)
            node.onOverscroll(overscrollValue)
            scrollView.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
        } else {
            node.onScroll(y)
        }
        didScroll()
    }
    /// The vlist's hook (the core's window follows the offset).
    func didScroll() {}

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        tempDisableBounce = false
        isTouched = true
        snapDragStartOffset = axis == .horizontal ? contentOffset.x : contentOffset.y
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if overscrollMode != .bounce { tempDisableBounce = true }
        isTouched = false
        overscrollValue = 0
        node?.onScrollRelease()
        if !decelerate { flushPendingKeyboardInsetClear() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        flushPendingKeyboardInsetClear()
    }

    // MARK: - the keyboard's contentInset (the host's native inset mode)

    /// Touching contentInset while the top rubber-band is bouncing back cancels UIKit's bounce
    /// (the content freezes mid-overscroll), and the `.onDrag` / `.interactive` dismissals hand
    /// the clear over while the finger is still down: a clear that lands mid-gesture is deferred
    /// to the settle.
    private var pendingKeyboardInsetClear = false

    /// The keyboard's band as a bottom inset: the view keeps its frame under the keyboard, the
    /// content stays where it is, only the scrollable range grows.
    func setKeyboardInset(_ inset: CGFloat) {
        pendingKeyboardInsetClear = false
        if contentInset.bottom != inset { contentInset.bottom = inset }
        if verticalScrollIndicatorInsets.bottom != inset { verticalScrollIndicatorInsets.bottom = inset }
    }
    func clearKeyboardInset() {
        guard contentInset.bottom != 0 else { pendingKeyboardInsetClear = false; return }
        if isTouched || isDecelerating || contentOffset.y < 0 {
            pendingKeyboardInsetClear = true
            return
        }
        pendingKeyboardInsetClear = false
        removeKeyboardInsetNow()
    }
    private func flushPendingKeyboardInsetClear() {
        guard pendingKeyboardInsetClear, !isTouched, !isDecelerating else { return }
        pendingKeyboardInsetClear = false
        removeKeyboardInsetNow()
    }
    private func removeKeyboardInsetNow() {
        let maxY = max(0, contentSize.height - bounds.height)
        let drop = {
            self.contentInset.bottom = 0
            self.verticalScrollIndicatorInsets.bottom = 0
        }
        if contentOffset.y > maxY, Animations.enabled {
            // Settled inside the phantom band the inset left behind (the keyboard is long gone from
            // under it): glide up to the real end first, dropping the inset there would snap.
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.contentOffset.y = maxY
            } completion: { _ in drop() }
        } else {
            if contentOffset.y > maxY { contentOffset.y = maxY }
            drop()
        }
    }

    /// Scroll so `rect` (content coordinates) sits inside the viewport above the keyboard inset,
    /// with breathing room. Manual math rather than scrollRectToVisible: that API ignores
    /// contentInset, and in native inset mode the keyboard band lives INSIDE the viewport.
    func reveal(_ rect: CGRect, margin: CGFloat) {
        let r = rect.insetBy(dx: 0, dy: -margin)
        let visible = bounds.height - contentInset.bottom
        guard visible > 0 else { return }
        var offset = contentOffset.y
        if r.maxY > offset + visible { offset = r.maxY - visible }
        if r.minY < offset { offset = r.minY }
        let maxOffset = contentSize.height + contentInset.bottom - bounds.height
        offset = max(0, min(offset, max(0, maxOffset)))
        if offset != contentOffset.y { setContentOffset(CGPoint(x: contentOffset.x, y: offset), animated: false) }
    }

    // MARK: - snap paging: where a direct child rests when a drag ends

    /// Two regimes, because "nearest to the projected offset" alone is wrong for flicks: at .fast
    /// deceleration UIKit's projection is SHORT, so a quick small swipe still lands on the page
    /// you came from. A flick commits exactly one child in the swipe direction, measured from
    /// where the drag STARTED (from the release point it would overshoot to +2); a slow release
    /// keeps the nearest-to-projection rule, so a carry past halfway commits and a carry back
    /// returns. The container's own padding insets the snap positions (CSS scroll-padding).
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard snapAlign != .none, let node, sheetPinnedOffsetY == nil else { return }
        let horizontal = axis == .horizontal
        let viewport = horizontal ? bounds.width : bounds.height
        let maxOffset = horizontal ? max(0, contentSize.width - bounds.width) : max(0, contentSize.height - bounds.height)
        let padding = CreatorUI.padding(node.id)
        let leading = CGFloat(horizontal ? padding.left : padding.top)
        let trailing = CGFloat(horizontal ? padding.right : padding.bottom)
        var offsets: [CGFloat] = []
        for child in node.children where !child.view.isHidden {
            let f = child.view.placement   // the layout's box, not a transformed child's bounding box
            let candidate: CGFloat
            switch snapAlign {
            case .start: candidate = (horizontal ? f.minX : f.minY) - (leading.isFinite ? leading : 0)
            case .center: candidate = (horizontal ? f.midX : f.midY) - viewport / 2
            case .end: candidate = (horizontal ? f.maxX : f.maxY) - viewport + (trailing.isFinite ? trailing : 0)
            case .none: candidate = 0
            }
            offsets.append(min(max(0, candidate), maxOffset))
        }
        offsets.sort()
        // Clamping can collapse the leading / trailing ones: near-duplicates are dropped, or
        // "advance one index" lands on the same offset and stalls.
        offsets = offsets.enumerated().filter { $0.offset == 0 || $0.element - offsets[$0.offset - 1] > 0.5 }.map { $0.element }
        guard !offsets.isEmpty else { return }
        func nearest(_ value: CGFloat) -> Int {
            var best = 0
            for (i, o) in offsets.enumerated() where abs(o - value) < abs(offsets[best] - value) { best = i }
            return best
        }
        let v = horizontal ? velocity.x : velocity.y
        let index: Int
        if abs(v) > ScrollContainerView.snapFlickVelocity {
            index = min(max(0, nearest(snapDragStartOffset) + (v > 0 ? 1 : -1)), offsets.count - 1)
        } else {
            index = nearest(horizontal ? targetContentOffset.pointee.x : targetContentOffset.pointee.y)
        }
        if horizontal { targetContentOffset.pointee.x = offsets[index] } else { targetContentOffset.pointee.y = offsets[index] }
    }

    // MARK: - pull-to-refresh

    func setRefreshEnabled(_ on: Bool) {
        if on, refreshControl == nil {
            let c = UIRefreshControl()
            c.addTarget(self, action: #selector(handleRefresh(_:)), for: .valueChanged)
            refreshControl = c
            alwaysBounceVertical = true
            if let tint = refreshTint { c.tintColor = tint }
            updateRefreshControlOffset()
        } else if !on, refreshControl != nil {
            refreshControl = nil
            alwaysBounceVertical = false
        }
    }
    /// nil = the platform's own spinner gray.
    var refreshTint: UIColor? { didSet { refreshControl?.tintColor = refreshTint } }

    @objc private func handleRefresh(_ sender: UIRefreshControl) {
        guard let node, !node.isRemoved else { sender.endRefreshing(); return }
        Core.refresh(node.id) { [weak sender] in sender?.endRefreshing() }
    }

    /// UIKit pins the control to the scroll view's TOP EDGE (its frame tracks contentOffset), so
    /// a full-bleed scrollable draws the spinner behind the status bar — gesture, hold and
    /// callback all work, nothing is visible. The shift rides on the control's BOUNDS, which UIKit
    /// leaves alone (it rewrites the frame on every scroll). A scrollable already below the safe
    /// area reports zero insets and is left untouched.
    private func updateRefreshControlOffset() {
        guard let refreshControl else { return }
        let shift = -safeAreaInsets.top
        if refreshControl.bounds.origin.y != shift { refreshControl.bounds.origin.y = shift }
    }
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateRefreshControlOffset()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRefreshControlOffset()
    }
}

/// The vlist's view: the core owns the window (creator-ui vlist.cpp) — this view drives it with
/// the scroll position (physical = logical px here) and its layout, and places each mounted item
/// at the core's offset (the items are detached yoga roots under the list node, not yoga
/// children). A core-initiated scroll (anchoring, a clamp) is buffered and applied after the
/// content height of the same pass, with the echo back into the core suppressed; a user command
/// animates. vlistOnScroll may re-enter JS synchronously (the SDK mounts inside the sync).
final class VListView: ScrollContainerView {
    var isAdjusting = false
    var pendingScrollY: CGFloat?

    override func didScroll() {
        guard !isAdjusting, sheetPinnedOffsetY == nil, let node, !node.isRemoved, contentOffset.y >= 0 else { return }
        CreatorUI.vlistOnScroll(node.id, scrollY: Float(contentOffset.y))   // may mount / unmount
        placeItems()
    }

    /// Every mounted item at the core's offset, the row at its own box inside its item root (its
    /// margins, its alignSelf). NaN = not mounted (a just-unmounted root: the lookup never
    /// dereferences it). Through `place`, never `frame`: a row may carry a transform (a press
    /// scale, a tween), and `frame` there is the transformed bounding box.
    func placeItems() {
        guard let node else { return }
        for child in Array(node.children) {
            let top = CGFloat(CreatorUI.vlistItemOffset(node.id, itemRoot: child.id))
            guard top.isFinite else { continue }
            let at = child.view.placement
            // the box the walk applied — Yoga's (the row is mounted: its node is live) before the first walk
            let o = child.lastLayout?.origin ?? LayoutBatch.read(child.id).origin
            let f = CGRect(x: o.x.isFinite ? o.x : 0, y: top + (o.y.isFinite ? o.y : 0), width: at.width, height: at.height)
            if at != f {
                if child.lastLayout == nil { UIView.performWithoutAnimation { child.view.place(f) } }   // a newborn item lands at once
                else { child.view.place(f) }
            }
        }
    }

    /// Apply a buffered anchored scroll AFTER the content height of this pass, then report where
    /// the view actually ended up: a scrollTo / scrollToKey command computes its target without
    /// touching the core's own scrollY, and an inverted chat would otherwise keep a stale
    /// `atBottom` and skip its autoscroll on every append.
    func applyPendingScroll() {
        guard let node, let target = pendingScrollY else { return }
        pendingScrollY = nil
        if abs(target - contentOffset.y) >= 1 {
            isAdjusting = true
            contentOffset = CGPoint(x: 0, y: target)
            isAdjusting = false
        }
        CreatorUI.vlistOnScroll(node.id, scrollY: Float(contentOffset.y))
    }
}
