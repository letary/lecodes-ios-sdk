// The box's shadows (`boxShadow`, docs/plans/shadow-plan.md and shadow-inset-plan.md) — BoxPaint's
// BoxShadows: one type, two SIDES, the list split by `inset` (each side in its own order, CSS's
// rule: the two are independent). A side exists only while it has a shadow, and both have one form:
// a container CALayer (no content of its own) holding one CALayer per shadow, the first shadow's
// on top (CSS paints [0] on top), each nothing but a `shadowPath` — the color's RGB as
// `shadowColor`, its alpha as `shadowOpacity`, `shadowRadius` = blur / 2 (CALayer's is the Gaussian
// sigma, CSS's blur is twice it) — and ONE clip on the container. Both are cut from one `Box`, the
// shape BoxPaint draws: the layer's cornerRadius on its maskedCorners, the clamp to half the box
// included (the pill); the paths are made again only when it changes. The layers never hit-test.
//
// The DROP side cannot live on the node's own layer: a clipping node (overflow hidden, a scroll
// container, an image) masks its bounds, and the overflow rules stand. So it lives BESIDE the node:
// its container in the PARENT view's layer, directly below the node's layer in the sublayers array,
// at the node layer's own zPosition — CA orders siblings by zPosition first and by index among
// equals, so the shadow paints over the earlier siblings and under the node (a zPosition a hair
// below would sink it under EVERY sibling at 0). The parent's overflow clips it like any content.
// A shadow's path is the box grown by `spread` (each drawn radius by CSS's spread rule, clamped at
// 0 — a square corner stays square, as in CSS), its `shadowOffset` (x, y). The clip — outside the
// box only — is an even-odd CAShapeLayer mask: the union of every shadow's extent (offset, grown,
// + 3 sigma) and the box, minus the box.
//
// The drop container is a copy of the node layer's geometry — bounds size (origin zero: a scroll
// view's offset is not the box), position, anchor, transform, opacity, hidden, zPosition — AND of
// the animations on those key paths: UIKit's (a sheet's spring, the keyboard curve: added to the
// layer synchronously inside the block) and LayerTween's (a screen transition), copied under the
// same key once they are on the layer — a copy keeps the beginTime, so both play the same curve.
//
// The INSET side lives INSIDE the node's layer, its container at BoxPaint.ZOrder.insetShadow: over
// the background (the layer's own color and contents, the effect, the color / image / gradient
// layers), under every child — inside the node's transform and opacity for free. The container is
// the box at the layer's bounds ORIGIN, which on a scroll view is the offset: the shadow stays on
// the box while the content scrolls (the border's and the gradient's way — a UIScrollView lays out
// on every scroll), and it clips to the box's rounded rect through `masksToBounds` on the box's own
// cornerRadius / maskedCorners — the very shape the background is drawn in — whatever the node's
// overflow says. A shadow's path is what CSS's inset shadow casts: everything OUTSIDE the inner
// rounded rect (`insetPath`), `shadowOffset` zero (the offset is in the inner rect).
//
// `follow` re-syncs both sides (compare-and-set: cheap when nothing moved) and is called by every
// writer of the node's layer: BoxPaint's (the frame, the transform with the sheet offset, opacity,
// display, the radius, layoutSublayers — which a scroll runs too), the frames the renderer places
// itself (the pager's pages, the vlist's rows), NodeView's isHidden (the pager hides pages),
// LayerTween's claim and release; and by the structure — every node view class's
// `didMoveToSuperview` (an insert, a reparent, a removal: the drop container goes with the view,
// the host's moves included) and, with `reorder`, the moves WITHIN one parent, which UIKit reports
// to nobody (a re-inserted child, the widget's bringToFront and its scrim, the pager's page order).
// Before the node's view has a parent (a screen root not yet mounted) the drop side has nowhere to
// go: the first follow after the mount attaches it. Nothing exists until the first non-empty list:
// a node without a shadow costs one nil check.
import LeCodesCore
import UIKit

final class BoxShadows {
    private unowned let view: UIView
    /// The drop shadows (in the parent's layer) and the inset ones (in the node's); nil while the
    /// list has none of that side.
    private(set) var drop: Side?
    private(set) var inset: Side?
    /// What the paths were made for.
    private var shapedFor: Box?

    init(view: UIView) { self.view = view }

    /// The list moved (the record's `boxShadow`, non-empty): each side made, restyled or gone, then
    /// the shape.
    func set(_ list: [Shadow]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        drop = BoxShadows.side(drop, list.filter { !$0.inset }, inset: false)
        inset = BoxShadows.side(inset, list.filter { $0.inset }, inset: true)
        shapedFor = nil
        follow()
    }

    private static func side(_ side: Side?, _ list: [Shadow], inset: Bool) -> Side? {
        if list.isEmpty { side?.detach(); return nil }
        let s = side ?? Side(inset: inset)
        s.set(list)
        return s
    }

    /// The list emptied: both sides go.
    func remove() {
        drop?.detach()
        inset?.detach()
        drop = nil
        inset = nil
    }

    /// Re-sync with the node's layer: each side's place, the geometry, the drop side's animations,
    /// the shape. `reorder`: the view moved within its parent — the drop container goes back
    /// directly below it.
    func follow(reorder: Bool = false) {
        let layer = view.layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let box = Box(of: layer)
        if let inset { place(inset: inset.container, in: layer, box) }
        if let drop { place(drop: drop, beside: layer, box, reorder: reorder) }
        if !box.isEmpty, shapedFor != box {
            shapedFor = box
            drop?.shape(box)
            inset?.shape(box)
        }
    }

    // MARK: - the places

    /// The inset container in the node's layer: the box at the bounds' ORIGIN (a scroll view's
    /// offset — it stays on the box while the content scrolls), clipped to the box's rounded rect.
    private func place(inset c: CALayer, in layer: CALayer, _ box: Box) {
        if c.superlayer !== layer { layer.addSublayer(c) }
        if c.bounds != box.rect { c.bounds = box.rect }
        let b = layer.bounds, center = CGPoint(x: b.midX, y: b.midY)
        if c.position != center { c.position = center }
        if c.cornerRadius != box.radius { c.cornerRadius = box.radius }
        if c.maskedCorners != box.corners { c.maskedCorners = box.corners }
        if c.isHidden != box.isEmpty { c.isHidden = box.isEmpty }   // a zero box
    }

    /// The drop container in the parent's layer, directly below the node's, a copy of its geometry
    /// and its animations.
    private func place(drop side: Side, beside layer: CALayer, _ box: Box, reorder: Bool) {
        let c = side.container
        guard let parent = layer.superlayer else {
            if c.superlayer != nil { side.detach() }
            return
        }
        if reorder || c.superlayer !== parent { parent.insertSublayer(c, below: layer) }
        if c.bounds != box.rect { c.bounds = box.rect }
        if c.anchorPoint != layer.anchorPoint { c.anchorPoint = layer.anchorPoint }
        if c.position != layer.position { c.position = layer.position }
        if !CATransform3DEqualToTransform(c.transform, layer.transform) { c.transform = layer.transform }
        if c.opacity != layer.opacity { c.opacity = layer.opacity }
        if c.zPosition != layer.zPosition { c.zPosition = layer.zPosition }
        let hidden = layer.isHidden || box.isEmpty   // rule 7: display none, a zero box
        if c.isHidden != hidden { c.isHidden = hidden }
        BoxShadows.mirrorAnimations(of: layer, on: c)
    }

    // MARK: - the sides

    /// One side: the container and a layer per shadow in it, aligned with `shadows`, held
    /// last-to-first (the first shadow's on top).
    final class Side {
        let isInset: Bool
        let container = CALayer()
        private(set) var layers: [CALayer] = []
        private(set) var shadows: [Shadow] = []
        /// The drop side's clip: the box cut out of the shadows' extent, even-odd.
        private let cutoutLayer: CAShapeLayer?

        init(inset: Bool) {
            isInset = inset
            if inset {
                container.name = "lc.insetShadow"
                container.zPosition = BoxPaint.ZOrder.insetShadow
                container.masksToBounds = true
                cutoutLayer = nil
            } else {
                container.name = "lc.boxShadow"
                let c = CAShapeLayer()
                c.fillRule = .evenOdd
                container.mask = c
                cutoutLayer = c
            }
        }

        /// The owner goes: the container with it — never an orphan shadow without its box.
        deinit { container.removeFromSuperlayer() }

        /// Off its layer (the side emptied, or the node's view has no parent for now).
        func detach() {
            container.removeAllAnimations()
            container.removeFromSuperlayer()
        }

        /// The side's shadows moved: the layers' style (the shape follows).
        func set(_ list: [Shadow]) {
            if list.count != layers.count {
                layers.forEach { $0.removeFromSuperlayer() }
                layers = list.map { _ in CALayer() }
                for l in layers.reversed() { container.addSublayer(l) }   // [0] last = on top
            }
            for (shadowLayer, s) in zip(layers, list) {
                shadowLayer.shadowOffset = isInset ? .zero : CGSize(width: CGFloat(s.x), height: CGFloat(s.y))
                shadowLayer.shadowRadius = BoxShadows.sigma(s)
                shadowLayer.shadowColor = UIColor(rgba: s.color | 0xFF).cgColor
                shadowLayer.shadowOpacity = Float(s.color & 0xFF) / 255
            }
            shadows = list
        }

        /// The paths for `box` (non-empty); the drop side's mask with them.
        func shape(_ box: Box) {
            let rect = box.rect
            var extent = rect
            for (shadowLayer, s) in zip(layers, shadows) {
                shadowLayer.frame = rect
                if isInset { shadowLayer.shadowPath = BoxShadows.insetPath(box, s); continue }
                shadowLayer.shadowPath = BoxShadows.dropPath(box, s)
                if let p = shadowLayer.shadowPath {
                    let reach = BoxShadows.reach(s)
                    extent = extent.union(p.boundingBox.offsetBy(dx: CGFloat(s.x), dy: CGFloat(s.y)).insetBy(dx: -reach, dy: -reach))
                }
            }
            guard let cutoutLayer else { return }
            // The mask in its own frame (the extent), the box cut out of it: even-odd = outside only.
            extent = extent.integral
            cutoutLayer.frame = extent
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: extent.size))
            path.addPath(BoxShadows.roundedRect(rect, radius: box.radius, corners: box.corners),
                         transform: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            cutoutLayer.path = path
        }
    }

    // MARK: - the shape

    /// The box both sides are cut from — what BoxPaint draws: the layer's cornerRadius on its
    /// maskedCorners, clamped to half the box (the pill).
    struct Box: Equatable {
        var size: CGSize
        var radius: CGFloat
        var corners: CACornerMask
        init(of layer: CALayer) {
            size = layer.bounds.size
            radius = max(0, min(layer.cornerRadius, min(size.width, size.height) / 2))
            corners = layer.maskedCorners
        }
        var rect: CGRect { CGRect(origin: .zero, size: size) }
        var isEmpty: Bool { !(size.width > 0 && size.height > 0) }
    }

    /// CALayer's shadowRadius is the Gaussian's sigma; CSS's blur is twice it.
    static func sigma(_ s: Shadow) -> CGFloat { CGFloat(max(s.blur, 0)) / 2 }
    /// How far a blurred edge reaches past its shape: 3 sigma and a little slack.
    static func reach(_ s: Shadow) -> CGFloat { 3 * sigma(s) + 2 }

    /// A corner radius grown by the spread, CSS's rule (what Chromium draws, what web-canvas and tgfx
    /// use): r + spread when r >= spread, a square corner stays square, and in between the growth
    /// eases in as r + spread × (1 + (r / spread − 1)³); a negative spread shrinks, floored at 0.
    static func spreadRadius(_ r: CGFloat, _ spread: CGFloat) -> CGFloat {
        if spread > 0 && r < spread { let t = r / spread - 1; return r + spread * (1 + t * t * t) }
        return max(0, r + spread)
    }

    /// A drop shadow's shape: the box grown by the spread, the radius by `spreadRadius`; nil when a
    /// negative spread ate the box.
    static func dropPath(_ box: Box, _ s: Shadow) -> CGPath? {
        let spread = CGFloat(s.spread)
        let grown = box.rect.insetBy(dx: -spread, dy: -spread)
        guard grown.width > 0, grown.height > 0 else { return nil }
        return roundedRect(grown, radius: spreadRadius(box.radius, spread), corners: box.corners)
    }

    /// An inset shadow's shape — what CSS casts "as if everything outside the box were opaque":
    /// everything outside the INNER rounded rect, the box moved by (x, y) and shrunk by the spread on
    /// every side, each radius by `spreadRadius(r, −spread)` (floored at 0: a positive spread makes
    /// the inner rect smaller and the shadow thicker). The outer contour is not the box but the box
    /// and the inner rect grown by the blur's reach: a frame that stopped at the box would blur the
    /// emptiness outside in and halve the shadow along the box's edge (an `inset 0 0 6px` would show
    /// nothing at all). The inner contour runs the other way round — shadowPath fills nonzero, so it
    /// is the hole. An inner rect the spread collapsed leaves no hole: the whole box is shadow, as
    /// it is where a large offset moved the inner rect off the box (the container's clip cuts the
    /// rest).
    static func insetPath(_ box: Box, _ s: Shadow) -> CGPath {
        let spread = CGFloat(s.spread)
        let inner = box.rect.offsetBy(dx: CGFloat(s.x), dy: CGFloat(s.y)).insetBy(dx: spread, dy: spread)
        let hole = !inner.isNull && inner.width > 0 && inner.height > 0
        let r = reach(s)
        let path = CGMutablePath()
        addRoundedRect(path, (hole ? box.rect.union(inner) : box.rect).insetBy(dx: -r, dy: -r), radius: 0, corners: [])
        if hole { addRoundedRect(path, inner, radius: spreadRadius(box.radius, -spread), corners: box.corners, reversed: true) }
        return path
    }

    /// The rounded rect CALayer draws for `cornerRadius` + `maskedCorners` (circular arcs, the
    /// default cornerCurve): `radius` on the masked corners, square elsewhere, clamped to half the rect.
    static func roundedRect(_ r: CGRect, radius: CGFloat, corners: CACornerMask) -> CGPath {
        let p = CGMutablePath()
        addRoundedRect(p, r, radius: radius, corners: corners)
        return p
    }

    /// `roundedRect` as a contour of `p`: top-left → top-right → bottom-right → bottom-left, or the
    /// other way round when `reversed` (a hole in what a nonzero fill covers).
    static func addRoundedRect(_ p: CGMutablePath, _ r: CGRect, radius: CGFloat, corners: CACornerMask, reversed: Bool = false) {
        let k = max(0, min(radius, min(r.width, r.height) / 2))
        let tl = corners.contains(.layerMinXMinYCorner) ? k : 0, tr = corners.contains(.layerMaxXMinYCorner) ? k : 0
        let br = corners.contains(.layerMaxXMaxYCorner) ? k : 0, bl = corners.contains(.layerMinXMaxYCorner) ? k : 0
        let a = CGPoint(x: r.minX, y: r.minY), b = CGPoint(x: r.maxX, y: r.minY)
        let c = CGPoint(x: r.maxX, y: r.maxY), d = CGPoint(x: r.minX, y: r.maxY)
        if reversed {
            p.move(to: CGPoint(x: r.minX, y: r.minY + tl))
            p.addArc(tangent1End: d, tangent2End: c, radius: bl)
            p.addArc(tangent1End: c, tangent2End: b, radius: br)
            p.addArc(tangent1End: b, tangent2End: a, radius: tr)
            p.addArc(tangent1End: a, tangent2End: d, radius: tl)
        } else {
            p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
            p.addArc(tangent1End: b, tangent2End: c, radius: tr)
            p.addArc(tangent1End: c, tangent2End: d, radius: br)
            p.addArc(tangent1End: d, tangent2End: a, radius: bl)
            p.addArc(tangent1End: a, tangent2End: b, radius: tl)
        }
        p.closeSubpath()
    }

    // MARK: - the drop side's animations

    /// The node layer's animations on the followed key paths, on the container under the same keys
    /// (a copy — re-adding replaces it with the same timing); the container's others go.
    private static func mirrorAnimations(of layer: CALayer, on container: CALayer) {
        let theirs = layer.animationKeys() ?? [], mine = container.animationKeys() ?? []
        if theirs.isEmpty && mine.isEmpty { return }
        var kept = Set<String>()
        for key in theirs {
            guard let a = layer.animation(forKey: key) as? CAPropertyAnimation, let path = a.keyPath, follows(path) else { continue }
            container.add(a, forKey: key)
            kept.insert(key)
        }
        for key in mine where !kept.contains(key) { container.removeAnimation(forKey: key) }
    }

    /// The geometry the drop container copies. Not `bounds` whole: its origin is a scroll view's
    /// offset (UIKit animates `bounds.size`).
    static func follows(_ keyPath: String) -> Bool {
        keyPath == "opacity" || keyPath.hasPrefix("transform") || keyPath.hasPrefix("position") || keyPath.hasPrefix("bounds.size")
    }
}
