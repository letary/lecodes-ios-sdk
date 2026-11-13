// The box every node draws (the old host's Node.swift + Border / CornerRadius / Gradient / Overflow
// utils, lifted) — BoxPaint over ANY UIView (a container's NodeView, the text label, the image
// view): the background color, the border (uniform = the layer's own, which follows the corner
// radius; per-side = one CALayer per visible edge, square: CALayer has no per-edge border), the
// radius (one cornerRadius = the largest, maskedCorners for which corners;
// clamped to half the box at layout, the `borderRadius: 9999` pill idiom — iOS does not clamp like
// the web), one CAGradientLayer under the content, the opacity as `alpha` (the layer's opacity,
// written where UIKit sees it — the glass follows it: `apply`), display none as isHidden, the
// overflow rule, the CSS transform with its origin folded into the matrix, and the backdrop
// effect. A view holds no style of its own: it draws the node's Paint, as the core resolved it,
// after every PaintBatch sync and every frame write.
//
// The backdrop (`backdropBlur` / `glass`, docs/plans/backdrop-plan.md): one UIVisualEffectView, a
// UIGlassEffect where `glass` is drawn (iOS 26, built with the iOS 26 SDK) — it wins over the blur,
// the background color is its tint and never a fill, a button's is interactive (`view is
// ButtonView`: the one node kind that claims its box for touches) — else `UIBlurEffect(.regular)`
// for any radius > 0 (rule 5 of the plan: UIKit has no public blur radius, and `.regular` is the
// style with the thinnest tint — measured on 2026-11-09 against Android's exact Gaussian; the
// system materials blur the same ~24 pt and veil far more). It is painted
// UNDER the node's own background: the view layer's own color and contents paint under every
// sublayer, so while an effect is on the color moves to a layer of its own above it (a blur) or
// into the tint (glass), and the image to its own layer like a tile. The order is BoxPaint.ZOrder's
// (by zPosition, never by index: the gradient's rule). A material is clipped to the rounded box;
// glass is not (it takes its shape from the corner radius itself, and a clip would cut its press
// stretch). The effect view is also the FIRST subview — NodeView sends it back after every child
// insert (hit-testing walks the subview order, and interactive glass takes touches; any other
// effect lets touches through, so an empty box still never swallows one). It is a subview, so the
// layer's transform, the sheet's offset and the opacity carry it (an opacity below 1 on it or an
// ancestor is UIKit's known limit: the effect cannot sample through a group). An image node draws
// none (its layer's contents is the picture), nor does a host node whose instance paints itself
// (UINodeHost, `paints: "self"`: its background color is left to it too).
//
// The shadows (`boxShadow`, BoxShadow.swift) have two sides. The drop shadows are the one paint that
// is NOT the view's: they live in the PARENT's layer directly below the node's layer (a clipping node
// masks its own bounds), in a container that copies the node layer's geometry and its animations.
// The inset ones are a rung of the ladder inside the box (over the gradient, under the children),
// clipped to the rounded box and kept on it while a scroll view scrolls. BoxShadow.swift says how
// both follow every writer (this class's frame / transform / opacity / display / radius writes and
// layoutSublayers call it) and the structure (`didMoveToSuperview` of each node view class,
// `reorder` for the moves within a parent).
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
    /// The box's paint order inside the node's layer, by zPosition — never by sublayer index: a
    /// subview move indexes the sublayers array and can drop a child's layer under a box layer (a
    /// display none → flex re-attach painted the gradient over text). CA sorts sublayers by
    /// zPosition, then by index among equals; the view layer's own color and contents paint under
    /// every sublayer. Every child sits at 0.
    enum ZOrder {
        /// The backdrop's UIVisualEffectView.
        static let effect: CGFloat = -4
        /// The background color on a layer of its own (over a blur).
        static let color: CGFloat = -3
        /// The background image on a layer of its own (tiled, or over an effect).
        static let image: CGFloat = -2
        static let gradient: CGFloat = -1
        /// The inset shadows' container (BoxShadow.swift).
        static let insetShadow: CGFloat = -0.5
        static let children: CGFloat = 0
        /// A screen's dim (ScreenView): over its content and its children.
        static let dim: CGFloat = 1
        /// The per-side border edges: over everything.
        static let border: CGFloat = 1000
    }

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
    /// The background image on a layer of its own (tiled, or over a backdrop effect); nil while it
    /// is the view layer's own `contents`.
    private var imageLayer: CALayer?
    private var overflow: CuiPaint.Overflow = .visible
    /// The backdrop effect (backdropBlur / glass): the effect view under everything the box paints,
    /// and the background color's own layer above it while the effect is a blur.
    private var backdrop = Backdrop.none
    private var effectView: UIVisualEffectView?
    private var colorLayer: CALayer?
    private var radius = Paint.Corners()
    /// The shadows, both sides; nil until the first non-empty list.
    private var shadows: BoxShadows?
    /// The CSS matrix and origin the node carries (the pivot is size-dependent, so the applied
    /// transform is re-derived from the current bounds at every writer).
    private var matrix: CGAffineTransform?
    /// The box part of `matrix` (a percent translate), folded against the current bounds at every
    /// writer like the pivot — never into `matrix` itself, which must survive a resize.
    private var box = Paint.TransformBox()
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
        if r.dirty(B.backgroundColor) || r.dirty(B.backdropBlur) || r.dirty(B.glass) { applyBackdrop(p) }
        // Through UIKit's `alpha`, not the layer's `opacity` (the same value — `alpha` reads it): UIKit
        // learns of a CHANGE only in the setter, and the glass under an ancestor follows it. A glass
        // view that enters the window while an ancestor is at 0 — a screen root re-mounted at a
        // fade's first pose — is set up unseen and drawn again only when UIKit sees that alpha
        // change; a layer write never told it, so the root faded in with its glass gone for good.
        if r.dirty(B.opacity) { view.alpha = p.opacity; shadows?.follow() }
        if r.dirty(B.display) { view.isHidden = p.display == .none; shadows?.follow() }
        if r.dirty(B.overflow) { overflow = p.overflow; applyOverflowClipping() }
        if r.dirty(B.borderTopLeftRadius) || r.dirty(B.borderTopRightRadius) || r.dirty(B.borderBottomRightRadius) || r.dirty(B.borderBottomLeftRadius) {
            radius = p.radius
            layoutCornerRadius()
            applyOverflowClipping()   // a radius arriving later starts clipping
            shadows?.follow()
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
            box = p.transformBox
            origin = p.transformOrigin
            applyTransform()
        }
        if r.dirty(B.pointerEvents) { view.isUserInteractionEnabled = p.pointerEvents }
        if r.dirty(B.boxShadow) { applyShadows(p.shadows) }
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
            if self.matrix != nil || self.offsetY != 0 { self.applyTransform() } else { self.shadows?.follow() }
        }
        if view.bounds.size == .zero && view.center == .zero { UIView.performWithoutAnimation(assign) } else { assign() }
    }

    /// From the view's layoutSubviews: the sublayer geometry follows the bounds (layout, not animation).
    func layoutSublayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutCornerRadius()
        layoutBackdrop()
        layoutBackground()
        layoutGradient()
        layoutBorderFrames()
        CATransaction.commit()
        shadows?.follow()
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
        for l in [effectView?.layer, colorLayer, imageLayer] {
            l?.cornerRadius = r
            l?.maskedCorners = layer.maskedCorners
        }
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

    // MARK: - backdrop

    /// What the box paints under its own background (docs/plans/backdrop-plan.md): nothing, the
    /// system blur (`.regular`, any `backdropBlur` > 0), or the system glass (`glass`, iOS 26+:
    /// where it is drawn it wins over the blur, takes the background color as its tint and reacts
    /// to touches on a button).
    enum Backdrop: Equatable {
        case none
        case blur(UIBlurEffect.Style)
        case glass(CuiPaint.Glass, tint: UInt32?, interactive: Bool)
    }

    /// The backdrop the paint asks for. `blur` is the record's value (px at the core's density —
    /// points on iOS, where the core runs at density 1): any radius > 0 is the one `.regular` blur.
    /// Not a paused `UIViewPropertyAnimator` over `effect` scrubbed by `fractionComplete` (the
    /// expo-blur radius trick): probed on iOS 26.5 / 26.6, the fraction is ignored and the full
    /// effect lands.
    static func backdrop(blur: CGFloat, glass: CuiPaint.Glass, background: UInt32?, interactive: Bool) -> Backdrop {
        #if compiler(>=6.2)   // UIGlassEffect is in the iOS 26 SDK (Xcode 26); an older one builds the fallback
        if glass != .none, #available(iOS 26, *) {
            let tint = background.flatMap { ($0 & 0xFF) == 0 ? nil : $0 }
            return .glass(glass, tint: tint, interactive: interactive)
        }
        #endif
        return blur > 0 ? .blur(.regular) : .none
    }

    /// backgroundColor / backdropBlur / glass moved: the effect, and where the color paints. No
    /// effect: the view's own backgroundColor (the plain path). A blur: the color on a layer of its
    /// own just above the effect view (rule 1: the node's background is not part of its backdrop),
    /// the view's own color nil — it paints under every sublayer, the effect's included. Glass: the
    /// color is the tint and paints nowhere else (rule 3). An image node draws none: its layer's own
    /// contents IS the picture, which the effect would cover. A host node whose instance paints itself
    /// takes none of the three (UINodeHost: `paints: "self"`).
    private func applyBackdrop(_ p: Paint) {
        if let host = view as? HostNodeBoxView, host.paintsSelf { return }
        let want = view is ImageView ? Backdrop.none
            : BoxPaint.backdrop(blur: p.backdropBlur, glass: p.glass, background: p.backgroundColor, interactive: view is ButtonView)
        let color = p.backgroundColor.map { UIColor(rgba: $0) }
        let movedImage = (want == .none) != (backdrop == .none)
        if want != backdrop {
            // A blur ⇄ glass switch makes the effect view again: one view never carries both kinds.
            if want == .none || BoxPaint.isGlass(want) != BoxPaint.isGlass(backdrop) {
                effectView?.removeFromSuperview()
                effectView = nil
            }
            backdrop = want
            if want != .none {
                let ev = effectView ?? makeEffectView()
                ev.effect = BoxPaint.effect(want)
                ev.isUserInteractionEnabled = BoxPaint.isInteractive(want)
                // A material is rounded only by the clip; glass shapes itself from the corner
                // radius (the same pixels at rest, probed) and its press stretch must not be cut.
                ev.clipsToBounds = !BoxPaint.isGlass(want)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case .blur = want {
            view.backgroundColor = nil
            let blurColorLayer = colorLayer ?? {
                let l = CALayer()
                l.zPosition = ZOrder.color
                l.cornerRadius = layer.cornerRadius
                l.maskedCorners = layer.maskedCorners
                layer.insertSublayer(l, at: 0)
                colorLayer = l
                return l
            }()
            blurColorLayer.frame = bounds
            blurColorLayer.backgroundColor = color?.cgColor
        } else {
            colorLayer?.removeFromSuperlayer()
            colorLayer = nil
            view.backgroundColor = want == .none ? color : nil
        }
        CATransaction.commit()
        if movedImage { showBackground() }   // the view layer's own contents ⇄ its own layer
    }

    /// The effect view: the FIRST subview at ZOrder.effect — under every sublayer the box paints
    /// and every child whatever the subview order (the gradient's rule); NodeView also keeps it
    /// first in the order, which is what hit-testing walks. Touches pass
    /// through it unless it is interactive glass (a button's, which claims its box anyway): then
    /// the glass sees the touch and the responder chain carries it on to the button.
    private func makeEffectView() -> UIVisualEffectView {
        let ev = UIVisualEffectView(effect: nil)
        ev.isUserInteractionEnabled = false
        ev.layer.zPosition = ZOrder.effect
        ev.layer.cornerRadius = layer.cornerRadius
        ev.layer.maskedCorners = layer.maskedCorners
        UIView.performWithoutAnimation {
            view.insertSubview(ev, at: 0)
            ev.place(bounds)
        }
        (view as? NodeView)?.backdropView = ev
        effectView = ev
        return ev
    }

    private static func effect(_ b: Backdrop) -> UIVisualEffect? {
        switch b {
        case .none: return nil
        case .blur(let style): return UIBlurEffect(style: style)
        case .glass(let style, let tint, let interactive):
            #if compiler(>=6.2)
            if #available(iOS 26, *) {
                let g = UIGlassEffect(style: style == .clear ? .clear : .regular)
                g.tintColor = tint.map { UIColor(rgba: $0) }
                g.isInteractive = interactive
                return g
            }
            #endif
            return nil
        }
    }

    private static func isGlass(_ b: Backdrop) -> Bool {
        if case .glass = b { return true }
        return false
    }

    private static func isInteractive(_ b: Backdrop) -> Bool {
        if case .glass(_, _, let interactive) = b { return interactive }
        return false
    }

    /// From layoutSublayers: the effect and the color layer cover the box (at the bounds' origin:
    /// a scroll view's effect stays on the box, as the border does).
    private func layoutBackdrop() {
        effectView?.place(bounds)   // a view (interactive glass stretches it on a press): never `frame`
        colorLayer?.frame = bounds
    }

    /// The layer the background color paints on — where a claimed backgroundColor tween plays
    /// (LayerTween): the view's own, the blur's color layer, none under glass (the color is the
    /// tint, which Core Animation cannot interpolate: the runtime keeps writing it).
    var backgroundColorLayer: CALayer? {
        switch backdrop {
        case .none: return layer
        case .blur: return colorLayer
        case .glass: return nil
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
                    l.zPosition = ZOrder.border
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
            backgroundToken = ImageLoader.image(src, shown: { [weak self] in self?.view.isShownOnScreen ?? false }) { [weak self] image in
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
    /// `contents` (under every sublayer: the gradient paints over it, as on the web) under a
    /// contents gravity; a radius clips it through the overflow rule's masksToBounds.
    /// tile: a gravity cannot repeat, so the image is the pattern of a layer of its own under the
    /// gradient — repeated at its natural size (points) from the box's top-left corner. Over a
    /// backdrop effect every size takes that layer: the view layer's own contents paint under every
    /// sublayer, the effect's included, and would be blurred away (rule 1).
    private func showBackground() {
        guard !(view is ImageView) else { return }   // its layer is its own image's
        let image = backgroundImage ?? renderBackgroundSvg()
        guard backgroundSize == .tile || backdrop != .none, let image else {
            imageLayer?.removeFromSuperlayer()
            imageLayer = nil
            layer.contents = backdrop == .none ? image?.cgImage : nil
            layer.contentsScale = image?.scale ?? UIScreen.main.scale
            layer.contentsGravity = BoxPaint.gravity(backgroundSize)
            return
        }
        layer.contents = nil
        let il = imageLayer ?? {
            let l = CALayer()
            l.zPosition = ZOrder.image
            l.masksToBounds = true
            l.cornerRadius = layer.cornerRadius
            l.maskedCorners = layer.maskedCorners
            layer.insertSublayer(l, at: 0)
            imageLayer = l
            return l
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if backgroundSize == .tile {
            il.contents = nil
            il.backgroundColor = UIColor(patternImage: image).cgColor
        } else {
            il.backgroundColor = nil
            il.contents = image.cgImage
            il.contentsScale = image.scale
            il.contentsGravity = BoxPaint.gravity(backgroundSize)
        }
        layoutBackground()
        CATransaction.commit()
    }

    private static func gravity(_ size: CuiPaint.BackgroundSize) -> CALayerContentsGravity {
        switch size {
        case .cover: return .resizeAspectFill
        case .contain: return .resizeAspect
        case .fill, .tile: return .resize
        }
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

    /// From layoutSublayers: an SVG sized by the box is drawn again when the box changed; the image
    /// layer follows the bounds and the radius.
    private func layoutBackground() {
        if backgroundSvg != nil && backgroundSize != .tile { showBackground() }
        guard let imageLayer else { return }
        imageLayer.frame = bounds
        imageLayer.cornerRadius = layer.cornerRadius
        imageLayer.maskedCorners = layer.maskedCorners
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
            // gradient over text. Its zPosition keeps it under every child for good.
            l.zPosition = ZOrder.gradient
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

    // MARK: - shadows

    /// boxShadow moved: the shadows made on the first non-empty list, gone with the last; a side
    /// (drop / inset) without a shadow holds no layer.
    private func applyShadows(_ all: [Shadow]) {
        // An image node draws no inset shadow: CSS hides it under the picture (docs/plans/shadow-inset-plan.md).
        let list = view is ImageView ? all.filter { !$0.inset } : all
        if list.isEmpty {
            shadows?.remove()
            shadows = nil
            return
        }
        let s = shadows ?? BoxShadows(view: view)
        shadows = s
        s.set(list)
    }

    /// The node's view moved in the tree, or a writer outside this class moved its layer (the
    /// pager, the vlist, a claimed tween): the shadow follows. `reorder`: within the same parent.
    func followShadow(reorder: Bool = false) { shadows?.follow(reorder: reorder) }

    /// The drop shadows' container in the parent's layer, the inset ones' in the node's (tests).
    var dropShadowContainer: CALayer? { shadows?.drop?.container }
    var insetShadowContainer: CALayer? { shadows?.inset?.container }

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

    /// The node's transform (the box part of a percent translate and the pivot folded in) with the
    /// sheet offset on top.
    func composedTransform() -> CGAffineTransform {
        matrix.map { composed(box.fold($0, bounds.size)) } ?? (offsetY != 0 ? CGAffineTransform(translationX: 0, y: offsetY) : .identity)
    }

    /// Any matrix composed the way the node's own is (a claimed transform tween's samples,
    /// LayerTween): the pivot folded in against the current box, the sheet offset on top.
    func composed(_ m: CGAffineTransform) -> CGAffineTransform {
        let base = folded(m)
        return offsetY != 0 ? base.translatedBy(x: 0, y: offsetY) : base
    }

    private func applyTransform() {
        view.transform = composedTransform()
        shadows?.follow()
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
        // TouchPipeline tracks pointers individually; UIKit must deliver the
        // second finger to the same button/screen for pinch gestures to work.
        isMultipleTouchEnabled = true
        clipsToBounds = false
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { nil }

    open override func layoutSubviews() {
        super.layoutSubviews()
        node?.box.layoutSublayers()
    }

    /// The box's shadow lives in the parent's layer: it goes where the view goes (BoxShadow.swift).
    open override func didMoveToSuperview() {
        super.didMoveToSuperview()
        node?.followShadow()
    }

    /// A touch that landed in here and is held by a target above ends with the view (HeldTouches).
    open override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { HeldTouches.viewLeftWindow(self) }
    }

    /// The pager hides and shows its pages itself.
    open override var isHidden: Bool { didSet { if isHidden != oldValue { node?.followShadow() } } }

    /// The backdrop effect BoxPaint put under the box (nil = none): kept the FIRST subview whatever
    /// a child insert does — children go in `at: 0` or above a sibling, and hit-testing walks the
    /// subview order (interactive glass takes touches); the render order is its zPosition's. A
    /// stored reference, never `node?.box`: subviews are added while the node's view is still
    /// being made (PagerMount), and the lazy box would make it again.
    weak var backdropView: UIView?

    open override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        if let b = backdropView, subview !== b, b.superview === self, subviews.first !== b { sendSubviewToBack(b) }
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
