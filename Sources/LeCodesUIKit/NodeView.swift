// The box every node draws (the old host's Node.swift + Border / CornerRadius / Gradient / Overflow
// utils, lifted) — BoxPaint over ANY UIView (a container's NodeView, the text label, the image
// view): the background color, the border (uniform = the layer's own, which follows the corner
// radius; per-side = one CALayer per visible edge, square: CALayer has no per-edge border), the
// radius (one cornerRadius = the largest, maskedCorners for which corners;
// clamped to half the box at layout, the `borderRadius: 9999` pill idiom — iOS does not clamp like
// the web), one CAGradientLayer under the content, the opacity on the LAYER, display none as
// isHidden, the overflow rule, and the CSS transform with its origin folded into the matrix. A view
// holds no style of its own: it draws the node's Paint, as the core resolved it, after every
// PaintBatch sync and every frame write.
//
// NodeView, the container's view, adds the hit-test rule: yoga-sized containers never clip, so a
// child can sit outside its parent's box, and UIKit's default bounds test would drop the touch at
// the PARENT — with no background on either view nothing hints where the real box ends, so a
// button would only respond where its content is. `point(inside:)` is widened by the subviews' own
// answer (the scan runs only for touches that would have been dropped; recursion comes from each
// child's override), and `hitTest` never returns the container itself — an empty box never swallows
// a touch, which is what makes the widening safe by construction. Interactive views (ScreenView,
// ButtonView) override that last rule.
import AnyCanvasPainter
import LeCodesCore
import UIKit

public final class BoxPaint {
    unowned let view: UIView
    private var layer: CALayer { view.layer }
    private var bounds: CGRect { view.bounds }

    private var borderLayers: [CALayer?] = [nil, nil, nil, nil]   // top, right, bottom, left
    private var borderWidths: [CGFloat] = [0, 0, 0, 0]
    private var gradientLayer: CAGradientLayer?
    private var gradient: Gradient?
    private var backgroundToken: ImageLoader.Token?
    private var backgroundSize: CuiPaint.BackgroundSize = .cover
    private var backgroundImage: UIImage?
    private var backgroundSvg: SvgDocument?
    private var backgroundSvgRendered: (pw: Int, ph: Int, image: UIImage)?
    private var tileLayer: CALayer?
    private var overflow: CuiPaint.Overflow = .visible
    private var radius = Paint.Corners()
    /// The CSS matrix and origin the node carries (the pivot is size-dependent, so the applied
    /// transform is re-derived from the current bounds at every writer).
    private var matrix: CGAffineTransform?
    private var origin = Paint.Origin()
    /// A translateY on top of the node's own transform — the sheet's detent offset (a pure
    /// transform, never a relayout); re-composed after every frame write.
    var offsetY: CGFloat = 0 { didSet { applyTransform() } }

    init(view: UIView) {
        self.view = view
        view.layer.contentsGravity = .resizeAspectFill
    }

    // MARK: - the paint

    /// The node's Paint moved (PaintBatch): sync the layer.
    func apply(_ p: Paint, dirty r: PaintRecord) {
        typealias B = CuiPaint.Bit
        if r.dirty(B.backgroundColor) { view.backgroundColor = p.backgroundColor.map { UIColor(rgba: $0) } }
        if r.dirty(B.opacity) { layer.opacity = Float(p.opacity) }
        if r.dirty(B.display) { view.isHidden = p.display == .none }
        if r.dirty(B.overflow) { overflow = p.overflow; applyOverflowClipping() }
        if r.dirty(B.borderTopLeftRadius) || r.dirty(B.borderTopRightRadius) || r.dirty(B.borderBottomRightRadius) || r.dirty(B.borderBottomLeftRadius) {
            radius = p.radius
            layoutCornerRadius()
            applyOverflowClipping()   // a radius arriving later starts clipping
        }
        if r.dirty(B.borderTopWidth) || r.dirty(B.borderRightWidth) || r.dirty(B.borderBottomWidth) || r.dirty(B.borderLeftWidth)
            || r.dirty(B.borderTopColor) || r.dirty(B.borderRightColor) || r.dirty(B.borderBottomColor) || r.dirty(B.borderLeftColor) {
            layoutBorders(p)
        }
        if r.dirty(B.backgroundImage) { applyBackgroundImage(p.backgroundImage) }
        if r.dirty(B.backgroundSize) { backgroundSize = p.backgroundSize; showBackground() }
        if r.dirty(B.backgroundGradient) { applyGradient(p.backgroundGradient) }
        if r.dirty(B.transform) || r.dirty(B.transformOrigin) {
            matrix = p.transform
            origin = p.transformOrigin
            applyTransform()
        }
        if r.dirty(B.pointerEvents) { view.isUserInteractionEnabled = p.pointerEvents }
    }

    // MARK: - the frame

    /// The box the core laid out, parent-relative points. A node's FIRST real frame is an
    /// appearance, not a move: a fresh view sits at .zero, and if the assignment lands inside an
    /// ambient animation block (the keyboard curve re-laying the screen while a tap handler adds
    /// content) UIKit animates the view growing out of zero — a visible glitch. The first layout is
    /// snapped; later frame changes ride the enclosing curve. The box lands as bounds + center
    /// (`place`), never as `frame`: a screen root mid-transition or under the edge swipe carries a
    /// transform (the animator's end value, while its presentation interpolates), and `frame`
    /// written under it moves the center by that transform — the top screen then sat a width to
    /// the left for the whole gesture. The pivot-folded transform is re-derived after a size change.
    func applyFrame(_ frame: CGRect) {
        let assign = {
            self.view.place(frame)
            if self.matrix != nil || self.offsetY != 0 { self.applyTransform() }
        }
        if view.bounds.size == .zero && view.center == .zero { UIView.performWithoutAnimation(assign) } else { assign() }
    }

    /// From the view's layoutSubviews: the sublayer geometry follows the bounds (layout, not animation).
    func layoutSublayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutCornerRadius()
        layoutBackground()
        layoutGradient()
        layoutBorderFrames()
        CATransaction.commit()
    }

    // MARK: - radius / overflow

    private func layoutCornerRadius() {
        let requested = max(radius.topLeft, radius.topRight, radius.bottomRight, radius.bottomLeft)
        let size = bounds.size
        // Before layout keep the raw value; once sized, clamp to half the box (the pill idiom).
        let r = size.width > 0 && size.height > 0 ? min(requested, min(size.width, size.height) / 2) : requested
        layer.cornerRadius = r
        var mask: CACornerMask = []
        if radius.topLeft > 0 { mask.insert(.layerMinXMinYCorner) }
        if radius.topRight > 0 { mask.insert(.layerMaxXMinYCorner) }
        if radius.bottomRight > 0 { mask.insert(.layerMaxXMaxYCorner) }
        if radius.bottomLeft > 0 { mask.insert(.layerMinXMaxYCorner) }
        layer.maskedCorners = mask.isEmpty ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMaxYCorner] : mask
        gradientLayer?.cornerRadius = r
        gradientLayer?.maskedCorners = layer.maskedCorners
    }

    /// Three states, not a flag: hidden clips, visible never, scroll clips exactly when the box has
    /// a radius. A node that never says `overflow` carries the registry default, `visible` (a
    /// record has no "unset"), so a radius alone never clips the children — the web's rule, and
    /// Android's (ContainerView clips under `!overflowVisible` only). A scroll container is
    /// a viewport: it clips whatever `overflow` says (the default `visible` let a scrolled list
    /// draw over the header above it). So does an image: what it draws is its layer's own
    /// contents, which a cornerRadius rounds only under masksToBounds — the default `visible`
    /// left an icon with a `borderRadius` square, and let a `cover` image draw outside its box.
    private func applyOverflowClipping() {
        if view is UIScrollView || view is ImageView { view.clipsToBounds = true; return }
        switch overflow {
        case .hidden: view.clipsToBounds = true
        case .visible: view.clipsToBounds = false
        case .scroll: view.clipsToBounds = layer.cornerRadius > 0
        }
    }

    // MARK: - borders

    private func layoutBorders(_ p: Paint) {
        let widths = [p.borderWidth.top, p.borderWidth.right, p.borderWidth.bottom, p.borderWidth.left]
        let colors = [p.borderColor.top, p.borderColor.right, p.borderColor.bottom, p.borderColor.left]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // One width and one color on every edge (`border: 1px solid …`, the common case): the
        // layer's own border, the only one that follows the corner radius — four edge rects drew a
        // square ring around a rounded field.
        let uniform = widths[0] > 0 && (colors[0] & 0xFF) != 0
            && widths.allSatisfy { $0 == widths[0] } && colors.allSatisfy { $0 == colors[0] }
        if uniform {
            layer.borderWidth = widths[0]
            layer.borderColor = UIColor(rgba: colors[0]).cgColor
            for i in 0..<4 { borderLayers[i]?.removeFromSuperlayer(); borderLayers[i] = nil }
            borderWidths = [0, 0, 0, 0]
            return
        }
        layer.borderWidth = 0
        for i in 0..<4 {
            let visible = widths[i] > 0 && (colors[i] & 0xFF) != 0
            if visible {
                let edge = borderLayers[i] ?? {
                    let l = CALayer()
                    l.zPosition = 1000   // above the content and the children
                    layer.addSublayer(l)
                    borderLayers[i] = l
                    return l
                }()
                edge.backgroundColor = UIColor(rgba: colors[i]).cgColor
            } else if let edge = borderLayers[i] {
                edge.removeFromSuperlayer()
                borderLayers[i] = nil
            }
        }
        borderWidths = widths
        layoutBorderFrames()
    }

    /// The edges at the bounds' ORIGIN, not (0, 0): a UIScrollView scrolls by moving its
    /// bounds, and the border must stay on the box, not ride away with the content.
    private func layoutBorderFrames() {
        let w = bounds.width, h = bounds.height, x0 = bounds.minX, y0 = bounds.minY
        let t = borderWidths[0], r = borderWidths[1], b = borderWidths[2], l = borderWidths[3]
        let frames = [
            CGRect(x: x0, y: y0, width: w, height: t),
            CGRect(x: x0 + w - r, y: y0, width: r, height: h),
            CGRect(x: x0, y: y0 + h - b, width: w, height: b),
            CGRect(x: x0, y: y0, width: l, height: h),
        ]
        for i in 0..<4 { borderLayers[i]?.frame = frames[i] }
    }

    // MARK: - background image

    /// The box's background image: a decoded image, or an SVG document (its pixels are made at the
    /// size the box shows it at — renderBackgroundSvg). Sources: an `id:` buffer (an asset, a fetched
    /// file — an SVG file sniffed), `svg:` markup, a url; a canvas / scene source is an image node's
    /// job. An image node's view keeps its layer for its own image.
    private func applyBackgroundImage(_ src: String) {
        backgroundToken?.cancel()
        backgroundToken = nil
        guard !(view is ImageView) else { return }
        if src.isEmpty { setBackgroundImage(nil); return }
        if src.hasPrefix("id:") {
            let data = Int(src.dropFirst(3)).flatMap { rendererServices?.buffer(id: $0) }
            if let data, SvgDocument.looksLikeSvg(data) { setBackgroundSvg(String(decoding: data, as: UTF8.self)) }
            else { setBackgroundImage(data.flatMap { UIImage(data: $0) }) }
        } else if src.hasPrefix("svg:") {
            setBackgroundSvg(String(src.dropFirst(4)))
        } else if src.hasPrefix("canvas:") || src.hasPrefix("scene2d:") {
            setBackgroundImage(nil)
        } else {
            backgroundToken = ImageLoader.image(src) { [weak self] image in
                guard let self else { return }
                self.backgroundToken = nil
                self.setBackgroundImage(image)
            }
        }
    }
    private func setBackgroundImage(_ image: UIImage?) {
        backgroundSvg = nil
        backgroundSvgRendered = nil
        backgroundImage = image
        showBackground()
    }
    private func setBackgroundSvg(_ markup: String) {
        backgroundImage = nil
        backgroundSvgRendered = nil
        backgroundSvg = SvgDocuments.get(markup)
        showBackground()
    }

    /// The image as `backgroundSize` shows it. cover / contain / fill: the view layer's own
    /// `contents` (under every sublayer: the gradient at zPosition -1 paints over it, as on the
    /// web) under a contents gravity; a radius clips it through the overflow rule's masksToBounds.
    /// tile: a gravity cannot repeat, so the image is the pattern of a layer of its own under the
    /// gradient — repeated at its natural size (points) from the box's top-left corner.
    private func showBackground() {
        guard !(view is ImageView) else { return }   // its layer is its own image's
        let image = backgroundImage ?? renderBackgroundSvg()
        guard backgroundSize == .tile, let image else {
            tileLayer?.removeFromSuperlayer()
            tileLayer = nil
            layer.contents = image?.cgImage
            layer.contentsScale = image?.scale ?? UIScreen.main.scale
            switch backgroundSize {
            case .cover: layer.contentsGravity = .resizeAspectFill
            case .contain: layer.contentsGravity = .resizeAspect
            case .fill, .tile: layer.contentsGravity = .resize
            }
            return
        }
        layer.contents = nil
        let tl = tileLayer ?? {
            let l = CALayer()
            l.zPosition = -2   // under the gradient (-1) and every child
            l.masksToBounds = true
            layer.insertSublayer(l, at: 0)
            tileLayer = l
            return l
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tl.backgroundColor = UIColor(patternImage: image).cgColor
        layoutBackground()
        CATransaction.commit()
    }

    /// The SVG's bitmap for the current box and `backgroundSize`: one cell at the natural size when
    /// tiled, otherwise the document at the scale the fit shows it at (the gravity then places it
    /// 1:1; `fill` stretches the larger of the two). Made again only when that pixel size changes.
    private func renderBackgroundSvg() -> UIImage? {
        guard let svg = backgroundSvg else { return nil }
        let w = CGFloat(svg.width), h = CGFloat(svg.height)
        var k: CGFloat = 1
        if backgroundSize != .tile {
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return nil }
            let kx = size.width / w, ky = size.height / h
            k = backgroundSize == .contain ? min(kx, ky) : max(kx, ky)
        }
        let scale = UIScreen.main.scale
        let pw = min(max(Int((w * k * scale).rounded()), 1), 4096), ph = min(max(Int((h * k * scale).rounded()), 1), 4096)
        if let r = backgroundSvgRendered, r.pw == pw, r.ph == ph { return r.image }
        guard let ctx = Surface.makeContext(width: pw, height: ph) else { return nil }
        let list = svg.draw(width: Float(pw), height: Float(ph))
        do {
            try CreatorCanvas.shared.painter.paint(ctx, DrawList(words: list.words, strings: list.strings))
        } catch {
            print("[BoxPaint] SVG background draw list failed: \(error)")
            return nil
        }
        guard let cg = ctx.makeImage() else { return nil }
        let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
        backgroundSvgRendered = (pw, ph, image)
        return image
    }

    /// From layoutSublayers: an SVG sized by the box is drawn again when the box changed; the tile
    /// layer follows the bounds and the radius.
    private func layoutBackground() {
        if backgroundSvg != nil && backgroundSize != .tile { showBackground() }
        guard let tileLayer else { return }
        tileLayer.frame = bounds
        tileLayer.cornerRadius = layer.cornerRadius
        tileLayer.maskedCorners = layer.maskedCorners
    }
    func cancelBackgroundLoad() {
        backgroundToken?.cancel()
        backgroundToken = nil
    }

    // MARK: - gradient

    private func applyGradient(_ g: Gradient?) {
        gradient = g
        guard let g else {
            gradientLayer?.removeFromSuperlayer()
            gradientLayer = nil
            return
        }
        let gl = gradientLayer ?? {
            let l = CAGradientLayer()
            l.needsDisplayOnBoundsChange = true
            // insertSublayer(at: 0) is not enough: a display none → flex re-attach indexes the
            // subviews array and can drop a child's layer beneath a non-subview layer, painting the
            // gradient over text. A negative zPosition keeps it under every child for good.
            l.zPosition = -1
            layer.insertSublayer(l, at: 0)
            gradientLayer = l
            return l
        }()
        gl.type = g.kind == .radial ? .radial : .axial
        gl.colors = g.stops.map { UIColor(rgba: $0.color).cgColor }
        gl.locations = g.stops.map { NSNumber(value: Double($0.position)) }
        layoutGradient()
    }

    private func layoutGradient() {
        guard let gradientLayer, let g = gradient else { return }
        gradientLayer.frame = bounds
        gradientLayer.cornerRadius = layer.cornerRadius
        gradientLayer.maskedCorners = layer.maskedCorners
        let size = bounds.size
        if g.kind == .radial {
            let (start, end) = BoxPaint.radialUnitPoints(g, size)
            gradientLayer.startPoint = start
            gradientLayer.endPoint = end
        } else {
            let (start, end) = BoxPaint.linearUnitPoints(angle: CGFloat(g.angle), size: size)
            gradientLayer.startPoint = start
            gradientLayer.endPoint = end
        }
    }

    /// CSS convention: 0 = up, 90 = right, clockwise; the gradient line's length is aspect-corrected
    /// (|w·dx| + |h·dy|) so the first and last stops touch the box's corners like the web.
    static func linearUnitPoints(angle: CGFloat, size: CGSize) -> (CGPoint, CGPoint) {
        let rad = angle * .pi / 180
        let dx = sin(rad), dy = -cos(rad)
        guard size.width > 0, size.height > 0 else { return (CGPoint(x: 0.5 - dx / 2, y: 0.5 - dy / 2), CGPoint(x: 0.5 + dx / 2, y: 0.5 + dy / 2)) }
        let len = abs(size.width * dx) + abs(size.height * dy)
        let hx = dx * len / 2 / size.width, hy = dy * len / 2 / size.height
        return (CGPoint(x: 0.5 - hx, y: 0.5 - hy), CGPoint(x: 0.5 + hx, y: 0.5 + hy))
    }

    /// The CSS radial table: the center as fractions, the radius by shape × extent (or explicit),
    /// as unit points of a CAGradientLayer (endPoint = center + radius / size).
    static func radialUnitPoints(_ g: Gradient, _ size: CGSize) -> (CGPoint, CGPoint) {
        let cx = CGFloat(g.center.x), cy = CGFloat(g.center.y)
        let w = max(size.width, 1), h = max(size.height, 1)
        let px = cx * w, py = cy * h
        var rx: CGFloat = 0, ry: CGFloat = 0
        switch g.extent {
        case .explicit:
            rx = g.radiusUnits.x == .fraction ? CGFloat(g.radii.x) * w : CGFloat(g.radii.x)
            ry = g.radiusUnits.y == .fraction ? CGFloat(g.radii.y) * h : CGFloat(g.radii.y)
        case .closestSide:
            rx = min(px, w - px); ry = min(py, h - py)
            if g.shape == .circle { rx = min(rx, ry); ry = rx }
        case .farthestSide:
            rx = max(px, w - px); ry = max(py, h - py)
            if g.shape == .circle { rx = max(rx, ry); ry = rx }
        case .closestCorner, .farthestCorner:
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)]
            let dists = corners.map { hypot($0.x - px, $0.y - py) }
            let d = g.extent == .closestCorner ? dists.min()! : dists.max()!
            if g.shape == .circle { rx = d; ry = d }
            else {
                // An ellipse through the corner with the closest-side / farthest-side aspect.
                let sx = g.extent == .closestCorner ? min(px, w - px) : max(px, w - px)
                let sy = g.extent == .closestCorner ? min(py, h - py) : max(py, h - py)
                if sx > 0, sy > 0 { let k = d / hypot(sx, sy); rx = sx * k; ry = sy * k } else { rx = d; ry = d }
            }
        }
        return (CGPoint(x: cx, y: cy), CGPoint(x: cx + rx / w, y: cy + ry / h))
    }

    // MARK: - transform

    /// The pivot folded into the matrix: T(p − c) · M · T(−(p − c)) in the view's own unrotated
    /// space, the anchorPoint never moved. Measured against the box, so re-derived at every writer.
    func folded(_ m: CGAffineTransform) -> CGAffineTransform {
        let size = bounds.size
        let px = origin.xIsFraction ? size.width * origin.x : origin.x
        let py = origin.yIsFraction ? size.height * origin.y : origin.y
        let dx = px - size.width / 2, dy = py - size.height / 2
        if dx == 0, dy == 0 { return m }
        return CGAffineTransform(translationX: -dx, y: -dy).concatenating(m).concatenating(CGAffineTransform(translationX: dx, y: dy))
    }

    /// The node's transform (the pivot folded in) with the sheet offset on top.
    func composedTransform() -> CGAffineTransform {
        matrix.map { composed($0) } ?? (offsetY != 0 ? CGAffineTransform(translationX: 0, y: offsetY) : .identity)
    }

    /// Any matrix composed the way the node's own is (a claimed transform tween's samples,
    /// LayerTween): the pivot folded in against the current box, the sheet offset on top.
    func composed(_ m: CGAffineTransform) -> CGAffineTransform {
        let base = folded(m)
        return offsetY != 0 ? base.translatedBy(x: 0, y: offsetY) : base
    }

    private func applyTransform() {
        view.transform = composedTransform()
    }
}

public extension UIView {
    /// Put the view at `r` (the superview's coordinates) through bounds + center, never `frame`:
    /// `frame` is undefined under a non-identity transform (an in-flight transition, the edge
    /// swipe), and writing it there moves the center by the transform. The bounds origin (a
    /// scroll view's offset) is kept; the anchor point is honoured.
    func place(_ r: CGRect) {
        if bounds.size != r.size { bounds = CGRect(origin: bounds.origin, size: r.size) }
        let a = layer.anchorPoint
        let c = CGPoint(x: r.minX + r.width * a.x, y: r.minY + r.height * a.y)
        if center != c { center = c }
    }

    /// Where the view was placed — what `place` wrote, read back the same way. Never `frame`:
    /// under a transform that is the transformed bounding box.
    var placement: CGRect {
        let a = layer.anchorPoint, s = bounds.size
        return CGRect(x: center.x - s.width * a.x, y: center.y - s.height * a.y, width: s.width, height: s.height)
    }
}

/// A container's view: the box, the children as subviews, the widened hit-test.
open class NodeView: UIView {
    public weak var node: UINode?

    public init(node: UINode) {
        self.node = node
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        clipsToBounds = false
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { nil }

    open override func layoutSubviews() {
        super.layoutSubviews()
        node?.box.layoutSublayers()
    }

    /// A child that would answer the touch, for a point outside this view's bounds.
    @inline(__always) static func subviewWantsPoint(_ view: UIView, _ point: CGPoint, _ event: UIEvent?) -> Bool {
        if view.clipsToBounds { return false }   // a clipping view shows nothing outside its bounds
        for sub in view.subviews where !sub.isHidden && sub.alpha >= 0.01 && sub.isUserInteractionEnabled {
            if sub.point(inside: sub.convert(point, from: view), with: event) { return true }
        }
        return false
    }

    open override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        return NodeView.subviewWantsPoint(self, point, event)
    }

    open override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit   // an empty container never swallows a touch
    }
}
