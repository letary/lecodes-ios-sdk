// One node of the tree of truth on the renderer's side — the twin of renderers/android's UINode.kt.
// The runtime owns the tree, the layout and the style cascade; a UINode is the handle the renderer
// keeps per id: the flag mask (what the node listens to), the content properties the runtime
// forwarded, the paint state the node's record last carried, the UIKit view that draws it (one view
// per node, as the old host had — created on first use) with its BoxPaint, and the apply walk that
// puts the frame's boxes on the views. Nothing here is read by the runtime.
//
// The apply walk is idempotent by construction: it READS every node's current box (LayoutBatch, non
// consuming) and diffs it against the box applied last time; a change reports TREE_EVENT_LAYOUT
// (gated on the flag) and moves the view, a fresh view gets its frame either way. So a re-walk, a
// rebuilt view, a widget shown again all converge on the same state — nothing has to remember
// whether an earlier pass "took" the layout.
import LeCodesCore
import UIKit

open class UINode {
    /// The node id: the runtime's node pointer, the key of Nodes.
    public let id: Int
    /// The wire type ("screen", "column", "text", …).
    public let type: String
    public private(set) weak var parent: UINodeContainer?
    /// The listener / trait mask (HostUI.setFlags, TREE_FLAG_* of TreeEvents): the renderer only
    /// reports an event kind the mask declares.
    public var flags: UInt32 = 0 { didSet { if flags != oldValue { flagsChanged() } } }
    public func has(_ flag: Int) -> Bool { (flags & UInt32(flag)) != 0 }
    /// releaseNode ran: the id is dead, its yoga node freed — never hand it to the core again.
    public private(set) var isRemoved = false
    /// The content properties as the runtime forwarded them ("text", "src", "value", "placeholder",
    /// "name", …); a nil write clears.
    public private(set) var content: [String: String] = [:]
    /// The paint state the node's record last carried (PaintBatch): what the view draws from.
    public var paint = Paint()
    /// The view (one per node; the type's own kind, `createView`), created on first use.
    public private(set) lazy var view: UIView = createView()
    /// The box painter over `view`.
    lazy var box = BoxPaint(view: view)
    /// The box applied last (parent-relative points), nil before the first layout.
    public private(set) var lastLayout: CGRect?
    /// The view's frame is the host's, not the node's box: a pager places its pages in tab cells
    /// (their own origin-anchored root box must never be applied).
    var frameOwnedByHost = false
    /// Set around a FrameBatcher-requested update: the walk goes through this node's children and
    /// its layoutFinished even when the frame's layout pass did not visit it — the request IS the
    /// change (a vlist mount outside the pass: the rows' boxes and their placement, a buffered
    /// scroll, a removed child's siblings).
    var walkRequested = false

    /// The core runs at density 1 on iOS: its px are points, a box reads straight into a frame (the
    /// old host's rule). Bitmaps scale by UIScreen.main.scale where they are decoded, not here.
    public static let density: CGFloat = 1
    /// The app root's view: the coordinate space widgets position in and getBoundingRect reports
    /// against. The host's root view sets it.
    public static weak var appRoot: UIView?

    public init(id: Int, type: String) {
        self.id = id
        self.type = type
    }

    /// A measured leaf (text, image, input): the core asks the renderer for its size during layout.
    open var hasMeasure: Bool { false }
    /// The view of this node's kind.
    func createView() -> UIView { NodeView(node: self) }
    /// The yoga measure (a measured leaf): the size within the constraints; mode 0 / NaN = none.
    func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize { .zero }
    /// A frame landed on the view (the text node reads its padding here).
    func frameApplied() {}
    /// The apply walk visited the node, changed or not (the sheet re-composes its offset here).
    func layoutVisited() {}
    /// The walk finished the node's children (a scrollable reads its content size, a vlist places
    /// its items).
    func layoutFinished() {}
    /// The listener / trait mask changed (a scrollable adds its refresh control).
    open func flagsChanged() {}

    // MARK: - the runtime's writes

    open func setProperty(_ prop: String, _ value: String?) {
        if let value { content[prop] = value } else { content.removeValue(forKey: prop) }
    }
    open func setPropertyInt(_ prop: String, _ value: Int32) {}

    /// One paint record (creator-ui/paint.gen.h) into this node — the whole style surface of the
    /// host contract. Only the fields the record marks dirty are applied; presence decides between a
    /// value and the node's own default. Text style arrives EFFECTIVE: the core inherits, the
    /// renderer never walks up. Type-scoped props no-op on other node types.
    open func applyPaint(_ r: PaintRecord) {
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        if r.dirty(B.backgroundColor) { paint.backgroundColor = r.has(B.backgroundColor) ? r.color(W.backgroundColor) : nil }
        // borders: the core fans borderWidth / borderColor out into the four sides (paint.cpp)
        if r.dirty(B.borderTopWidth) { paint.borderWidth.top = CGFloat(r.float(W.borderTopWidth)) }
        if r.dirty(B.borderRightWidth) { paint.borderWidth.right = CGFloat(r.float(W.borderRightWidth)) }
        if r.dirty(B.borderBottomWidth) { paint.borderWidth.bottom = CGFloat(r.float(W.borderBottomWidth)) }
        if r.dirty(B.borderLeftWidth) { paint.borderWidth.left = CGFloat(r.float(W.borderLeftWidth)) }
        if r.dirty(B.borderTopColor) { paint.borderColor.top = r.color(W.borderTopColor) }
        if r.dirty(B.borderRightColor) { paint.borderColor.right = r.color(W.borderRightColor) }
        if r.dirty(B.borderBottomColor) { paint.borderColor.bottom = r.color(W.borderBottomColor) }
        if r.dirty(B.borderLeftColor) { paint.borderColor.left = r.color(W.borderLeftColor) }
        if r.dirty(B.borderTopLeftRadius) { paint.radius.topLeft = CGFloat(r.float(W.borderTopLeftRadius)) }
        if r.dirty(B.borderTopRightRadius) { paint.radius.topRight = CGFloat(r.float(W.borderTopRightRadius)) }
        if r.dirty(B.borderBottomRightRadius) { paint.radius.bottomRight = CGFloat(r.float(W.borderBottomRightRadius)) }
        if r.dirty(B.borderBottomLeftRadius) { paint.radius.bottomLeft = CGFloat(r.float(W.borderBottomLeftRadius)) }
        if r.dirty(B.opacity) { paint.opacity = CGFloat(r.float(W.opacity)) }
        if r.dirty(B.display) { paint.display = CuiPaint.Display(rawValue: r.word(W.display)) ?? .flex }
        if r.dirty(B.overflow) { paint.overflow = CuiPaint.Overflow(rawValue: r.word(W.overflow)) ?? .visible }
        if r.dirty(B.backgroundImage) { paint.backgroundImage = r.string(W.backgroundImage) }
        if r.dirty(B.backgroundSize) { paint.backgroundSize = CuiPaint.BackgroundSize(rawValue: r.word(W.backgroundSize)) ?? .cover }
        if r.dirty(B.backgroundGradient) { paint.backgroundGradient = r.gradient(W.backgroundGradient) }
        if r.dirty(B.transform) { paint.transform = r.transform(W.transform) }
        if r.dirty(B.transformOrigin) {
            // The core dispatches a percentage axis as 0..100 (the registry default "50% 50%" arrives
            // as 50, like tgfx / Android read it); the box folds a FRACTION of its size into the
            // matrix. Read as-is, a spinner's rotate pivoted 50 widths away and swept off the screen.
            let xPercent = r.word(W.transformOrigin + 2) != 0, yPercent = r.word(W.transformOrigin + 3) != 0
            let x = CGFloat(r.float(W.transformOrigin)), y = CGFloat(r.float(W.transformOrigin + 1))
            paint.transformOrigin = Paint.Origin(x: xPercent ? x / 100 : x, y: yPercent ? y / 100 : y,
                                                 xIsFraction: xPercent, yIsFraction: yPercent)
        }
        if r.dirty(B.pointerEvents) { paint.pointerEvents = r.word(W.pointerEvents) != CuiPaint.PointerEvents.none.rawValue }
        box.apply(paint, dirty: r)
    }

    // MARK: - the lifecycle

    func markRemoved() { isRemoved = true }
    /// The node was released by the runtime: drop what it holds outside the tree.
    open func onRemoved() { box.cancelBackgroundLoad() }

    func attached(to parent: UINodeContainer?) { self.parent = parent }

    /// The apply walk from this node (FrameBatcher, the root view's layout pass): the frame's boxes
    /// onto the views, TREE_EVENT_LAYOUT for the nodes that listen. With the batch active a subtree
    /// the pass did not visit is pruned; a structural pass (batch inactive: a screen just presented,
    /// a view rebuilt) walks everything.
    public func updateLayout() { applyLayoutWalk() }

    func applyLayoutWalk() {
        guard !isRemoved else { return }
        if paint.display == .none { return }   // out of the layout (and hidden): nothing to apply below
        let r = LayoutBatch.read(id)
        // Yoga's pre-layout NaN: the node has not been through a layout pass yet — keep the last box.
        guard r.origin.x.isFinite, r.origin.y.isFinite, r.width.isFinite, r.height.isFinite else { return }
        let changed = lastLayout != r
        if changed {
            lastLayout = r
            if !frameOwnedByHost { applyBox(r) }
            frameApplied()
            if has(TreeEvents.TREE_FLAG_LAYOUT) {
                Core.nodeLayout(id, left: Float(r.origin.x), top: Float(r.origin.y), width: Float(r.width), height: Float(r.height))
            }
        } else if !frameOwnedByHost, boxDiffers(from: r) {
            applyBox(r)   // a fresh view gets its box either way
            frameApplied()
        }
        layoutVisited()
        guard let container = self as? UINodeContainer else { return }
        if LayoutBatch.active, !changed, !LayoutBatch.visited(id), !walkRequested { return }
        for child in container.children { child.applyLayoutWalk() }   // a copy: a vlist sync can mutate the list
        layoutFinished()
    }

    /// The box lands on the view — through the vlist for one of its rows: a row sits in a detached
    /// item root, its Yoga box is relative to that root and the root's y is the list's offset.
    /// Without this, any later update of a row (an avatar that loaded, a style write) re-applied
    /// the box against 0 and an inverted chat's message jumped to the top — whenever that update
    /// landed after the placement.
    private func applyBox(_ r: CGRect) {
        if let list = parent as? UINodeVList { list.placeRow(self, box: r) } else { box.applyFrame(r) }
    }
    /// Never through `view.frame`: under a transform (a spinner's rotate) it is the rotated bounding
    /// box, so the comparison re-placed the view at every walk. The box lands as bounds + center
    /// (`place`), so it is compared the same way.
    private func boxDiffers(from r: CGRect) -> Bool {
        if view.bounds.size != r.size { return true }
        if parent is UINodeVList { return false }
        let a = view.layer.anchorPoint
        return view.center != CGPoint(x: r.minX + r.width * a.x, y: r.minY + r.height * a.y)
    }

    /// HostUI.getBoundingRect: [left, top, width, height] in the app root's space, points, live (a
    /// scroll or a transition moves a node without a layout; the view sees it, the cached box does
    /// not); nil when the node is not mounted under the root or never laid out.
    func boundingRect() -> [Float]? {
        guard lastLayout != nil, let root = UINode.appRoot, view.isDescendant(of: root) else { return nil }
        let r = view.convert(view.bounds, to: root)
        return [Float(r.origin.x), Float(r.origin.y), Float(r.width), Float(r.height)]
    }

    /// The measure func creator-ui calls during layout, installed once (HostUIRenderer): a measure
    /// that runs before this frame's paint sync reads the node's record itself (PaintBatch.applyPending).
    static func installMeasure() {
        Core.setMeasureFunc { _, ptr, width, widthMode, height, heightMode in
            guard let ptr, let node = Nodes[Int(bitPattern: ptr)], !node.isRemoved else { return 0 }
            PaintBatch.applyPending(node)
            let size = node.measure(width: width, widthMode: widthMode, height: height, heightMode: heightMode)
            return Core.packMeasure(width: Float(size.width), height: Float(size.height))
        }
    }
}

/// The common paint state of a node (the box's look), as the core resolved it. Colors are the core's
/// 0xRRGGBBAA; sizes logical px.
public struct Paint {
    public struct Sides<T> { public var top: T; public var right: T; public var bottom: T; public var left: T }
    public struct Corners { public var topLeft: CGFloat = 0, topRight: CGFloat = 0, bottomRight: CGFloat = 0, bottomLeft: CGFloat = 0 }
    public struct Origin { public var x: CGFloat = 0.5, y: CGFloat = 0.5, xIsFraction = true, yIsFraction = true }

    public var backgroundColor: UInt32?
    public var backgroundImage = ""
    public var backgroundSize: CuiPaint.BackgroundSize = .cover
    public var backgroundGradient: Gradient?
    public var borderWidth = Sides<CGFloat>(top: 0, right: 0, bottom: 0, left: 0)
    public var borderColor = Sides<UInt32>(top: 0, right: 0, bottom: 0, left: 0)
    public var radius = Corners()
    public var opacity: CGFloat = 1
    public var display: CuiPaint.Display = .flex
    public var overflow: CuiPaint.Overflow = .visible
    /// nil = identity.
    public var transform: CGAffineTransform?
    public var transformOrigin = Origin()
    public var pointerEvents = true
    public init() {}
}

/// A container: its children in tree order (the runtime's insert / remove, mirrored here so a view
/// can place them). A pager's children are its PAGES, a vlist's its mounted items.
open class UINodeContainer: UINode {
    public private(set) var children: [UINode] = []

    func insert(_ child: UINode, at index: Int) {
        if let i = children.firstIndex(where: { $0 === child }) { children.remove(at: i) }
        children.insert(child, at: min(max(index, 0), children.count))
        child.attached(to: self)
        if self is UINodePager { child.frameOwnedByHost = true }   // a page sits in its tab cell
        childInserted(child)
    }
    func remove(_ child: UINode) {
        guard let i = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: i)
        child.attached(to: nil)
        childRemoved(child)
    }
    /// The child's view goes under this view, in the children's order: above the previous sibling's
    /// view (a view may hold non-node subviews too — an attached widget — so never by index).
    func childInserted(_ child: UINode) {
        let i = children.firstIndex { $0 === child } ?? 0
        if i > 0 { view.insertSubview(child.view, aboveSubview: children[i - 1].view) }
        else { view.insertSubview(child.view, at: 0) }
        FrameBatcher.request(self)
    }
    func childRemoved(_ child: UINode) {
        child.view.removeFromSuperview()
        FrameBatcher.request(self)
    }
}
