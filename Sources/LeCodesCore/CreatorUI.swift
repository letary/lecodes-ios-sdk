// The style engine's surface for the renderer — the twin of hosts/android's CreatorUI natives
// (creator-ui-jni.cpp) over the C face (lecodes-core.h lc_ui*): the layout reads and writes, the
// paint-record batch a renderer pulls once per frame, the safe-area and keyboard writes, the
// virtualized list's routing. A node is its id (an Int: the runtime's node pointer, the same number
// HostUI.nodeFactory handed the renderer). Everything on the JS thread (the main thread).
import Foundation
import CLeCodesCore

public enum CreatorUI {
    // MARK: - Layout

    /// Lay one root out at (width, height): a screen / pager-page root. The frame's pass over EVERY
    /// live root is Core.layoutFrame; this is a host's own out-of-band recalc.
    public static func calculate(_ root: Int, width: Float, height: Float) { lc_uiCalculate(Core.node(root), width, height) }
    /// A widget root, through its centering auto-root.
    public static func calculateWidget(_ root: Int, width: Float, height: Float) { lc_uiCalculateWidget(Core.node(root), width, height) }
    /// Re-lay the last calculate()'s root.
    public static func recalculate() { lc_uiRecalculate() }
    /// A style write landed since the last ask (cleared by the ask): the frame runs its layout pass.
    public static func consumeNeedsLayout() -> Bool { lc_uiConsumeNeedsLayout() }
    /// The node's CURRENT box {left, top, width, height} in its parent's space, the core's px — an
    /// ungated read (yoga's one-shot hasNewLayout flag untouched), for a node the frame's layout
    /// batch did not carry.
    public static func layout(_ node: Int) -> (left: Float, top: Float, width: Float, height: Float) {
        var out: [Float] = [0, 0, 0, 0]
        lc_uiGetLayout(Core.node(node), &out)
        return (out[0], out[1], out[2], out[3])
    }
    /// The node's padding {left, top, right, bottom}.
    public static func padding(_ node: Int) -> (left: Float, top: Float, right: Float, bottom: Float) {
        var out: [Float] = [0, 0, 0, 0]
        lc_uiGetPadding(Core.node(node), &out)
        return (out[0], out[1], out[2], out[3])
    }
    /// Yoga permits manual dirtying of MEASURE nodes only (a leaf whose intrinsic size changed).
    public static func markNodeDirty(_ node: Int) { lc_uiMarkNodeDirty(Core.node(node)) }
    /// A scrollable's content extent, logical px.
    public static func contentHeight(_ node: Int) -> Float { lc_uiContentHeight(Core.node(node)) }
    public static func contentWidth(_ node: Int) -> Float { lc_uiContentWidth(Core.node(node)) }

    // MARK: - The paint state (creator-ui/paint.gen.h; the reader in CuiPaint.gen.swift)

    /// Every node whose record changed since the last collect: the batch size. The batch (paintNodes /
    /// paintRecords) stays valid until the next collect; the dirty marks are cleared by it.
    public static func paintCollect() -> Int { Int(lc_uiPaintCollect()) }
    /// The collected node ids, `count` of them.
    public static func paintNodes(count: Int) -> UnsafeBufferPointer<UnsafeRawPointer?> {
        UnsafeBufferPointer(start: lc_uiPaintNodes(), count: count)
    }
    /// The collected records: record i starts at word i * CuiPaint.words.
    public static func paintRecords() -> UnsafePointer<UInt32>? { lc_uiPaintRecords() }
    /// One live node's CURRENT record in place (CuiPaint.words 32-bit words), nil for a dead node.
    public static func paintOf(_ node: Int) -> UnsafePointer<UInt32>? { lc_uiPaintOf(Core.node(node)) }
    /// An interned string id ("" for 0).
    public static func string(_ id: UInt32) -> String { lc_uiStringOf(id).map { String(cString: $0) } ?? "" }
    /// The topmost layer of a gradient id (a copy), nil for 0 / an unknown id.
    public static func gradient(_ id: UInt32) -> Gradient? {
        var g = LcGradient()
        guard lc_uiGradientOf(id, &g), let stops = g.stops else { return nil }
        let count = Int(g.stopCount)
        return Gradient(
            kind: g.type == 1 ? .radial : .linear,
            angle: g.angle,
            stops: (0..<count).map { Gradient.Stop(color: stops[$0].color, position: stops[$0].position) },
            shape: g.shape == 1 ? .circle : .ellipse,
            extent: Gradient.Extent(rawValue: g.extent) ?? .farthestCorner,
            center: (g.cx, g.cy),
            radii: (g.rx, g.ry),
            radiusUnits: (g.rUnitX == 1 ? .fraction : .px, g.rUnitY == 1 ? .fraction : .px))
    }

    // MARK: - Safe area, density, the state layers

    /// The global safe paddings (root 0: every live root re-resolves its safe- / comfort- styles),
    /// or one root's. Logical px.
    public static func setSafePaddings(top: Float, right: Float, bottom: Float, left: Float, root: Int = 0) {
        lc_uiSetSafePaddings(top, right, bottom, left, Core.node(root))
    }
    /// The edges a system bar occupies (top=1 right=2 bottom=4 left=8): a clearance style floors
    /// them. BEFORE setSafePaddings, to relayout once.
    public static func setSafeAreaBars(_ edges: UInt32) { lc_uiSetSafeAreaBars(edges) }
    /// The scoped keyboard collapse: ONE root's bottom safe inset, the globals untouched.
    public static func overrideRootSafeBottom(_ root: Int, bottom: Float) { lc_uiOverrideRootSafeBottom(Core.node(root), bottom) }
    /// The core's px per logical px. The iOS renderer runs the core at 1 (its px are points, the
    /// old host's rule); Android hands its display density (its views are physical).
    public static func setDensity(_ density: Float) { lc_uiSetDensity(density) }
    /// The viewport the vw / vh / orientation conditions resolve against.
    public static func setConditionValue(width: Float, height: Float) { lc_uiSetConditionValue(width, height) }
    public static func setNodePressed(_ node: Int, _ pressed: Bool) { lc_uiSetNodePressed(Core.node(node), pressed) }
    public static func setNodeFocused(_ node: Int, _ focused: Bool) { lc_uiSetNodeFocused(Core.node(node), focused) }

    // MARK: - The virtualized list (main thread: may re-enter JS synchronously)

    /// The host scroll view's position, PHYSICAL px.
    public static func vlistOnScroll(_ list: Int, scrollY: Float) { lc_uiVlistOnScroll(Core.node(list), scrollY) }
    /// After the frame's layout pass, for the list node.
    public static func vlistUpdateLayout(_ list: Int) { lc_uiVlistUpdateLayout(Core.node(list)) }
    /// An item's absolute top (physical px) by its root node; NaN when it is not mounted.
    public static func vlistItemOffset(_ list: Int, itemRoot: Int) -> Float { lc_uiVlistItemOffsetOf(Core.node(list), Core.node(itemRoot)) }
}

/// One gradient layer as the core resolved it (CUIGradient of creator-ui.h). Colors are the core's
/// 0xRRGGBBAA, positions 0…1.
public struct Gradient: Equatable {
    public enum Kind { case linear, radial }
    public enum Shape { case ellipse, circle }
    public enum Extent: UInt32 { case farthestCorner = 0, closestSide = 1, closestCorner = 2, farthestSide = 3, explicit = 4 }
    public enum RadiusUnit { case px, fraction }
    public struct Stop: Equatable {
        public let color: UInt32
        public let position: Float
        public init(color: UInt32, position: Float) { self.color = color; self.position = position }
    }
    public let kind: Kind
    /// Linear: degrees, CSS convention (0 = up, 90 = right, clockwise).
    public let angle: Float
    public let stops: [Stop]
    public let shape: Shape
    public let extent: Extent
    /// Radial: the center as fractions of the box.
    public let center: (x: Float, y: Float)
    /// Radial, extent .explicit: the radii, each in `radiusUnits`.
    public let radii: (x: Float, y: Float)
    public let radiusUnits: (x: RadiusUnit, y: RadiusUnit)

    public static func == (a: Gradient, b: Gradient) -> Bool {
        a.kind == b.kind && a.angle == b.angle && a.stops == b.stops && a.shape == b.shape && a.extent == b.extent
            && a.center == b.center && a.radii == b.radii && a.radiusUnits == b.radiusUnits
    }
}
