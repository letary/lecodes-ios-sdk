// The Apple painter: replays a draw list on a CGContext. One case per command, exhaustive over
// DrawCommand (no default: a new command in spec/draw.h fails to compile here until it is handled),
// no state beyond the context's own save stack and the transform the list set last.
//
// Coordinates: the draw list is y-down (Canvas2D); a CGContext is y-up. The painter does NOT flip —
// the CTM it finds at entry is the BASE (a bitmap surface's y-flip, see Surface.swift; a UIView's
// draw(_:) context is already flipped), and the list's absolute SET_TRANSFORM matrices are applied
// as DELTAS on top of it (`target · applied⁻¹`, the Android painter's rule): a later matrix must
// land where the list says, never composed with the previous one. Under a singular matrix nothing
// is visible: the draws are skipped and a clip empties the clip (Canvas2D semantics).
//
// Platform limits, stated: CoreGraphics has no gradient tiling — REFLECT / REPEAT are drawn by
// extending the stops over the clip's bounds in gradient space; text is CoreText's (fallback fonts and
// color emoji are the platform's, glyph pixels differ from every other painter).
import CoreGraphics
import CoreText
import Foundation
import AnyCanvasSpec

/// What the painter needs from its host. The defaults make it usable standalone.
public protocol PainterHooks {
    /// The CTFont for a resolved font (a registered font by family first, then the system).
    func font(_ font: FontData) -> CTFont
    /// The image of a surface id, for DRAW_IMAGE; nil skips the blit.
    func image(_ surface: Int32) -> CGImage?
}

public extension PainterHooks {
    func font(_ font: FontData) -> CTFont { Fonts.resolve(font) }
    func image(_ surface: Int32) -> CGImage? { nil }
}

/// The standalone hooks: system fonts, no images.
public struct DefaultHooks: PainterHooks {
    public init() {}
}

public final class Painter {
    public let hooks: PainterHooks
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let transparent = cgColor(Color(r: 0, g: 0, b: 0, a: 0))

    public init(hooks: PainterHooks = DefaultHooks()) { self.hooks = hooks }

    /// Replay `list` on `ctx`. The context's current transform is the base; clearing is the caller's.
    public func paint(_ ctx: CGContext, _ list: DrawList) throws { paint(ctx, try list.commands()) }

    public func paint(_ ctx: CGContext, _ commands: [DrawCommand]) {
        // `applied`: the last INVERTIBLE matrix of the list on the context (on top of the base);
        // `visible`: the list's current matrix is invertible.
        var applied = CGAffineTransform.identity
        var visible = true
        var stack: [(CGAffineTransform, Bool)] = []
        var saves = 0   // a list RESTORE never pops the wrapper save
        // The replay runs inside one save, so no clip, transform or style it sets outlives it (a
        // list-level CLIP without SAVE would otherwise shrink the next paint's clear).
        ctx.saveGState()
        ctx.setAlpha(1)
        ctx.setLineDash(phase: 0, lengths: [])
        for c in commands {
            switch c {
            case .setTransform(let m):
                let target = CGAffineTransform(a: CGFloat(m.a), b: CGFloat(m.b), c: CGFloat(m.c), d: CGFloat(m.d), tx: CGFloat(m.e), ty: CGFloat(m.f))
                let det = target.a * target.d - target.b * target.c
                visible = det != 0 && det.isFinite && [target.a, target.b, target.c, target.d, target.tx, target.ty].allSatisfy { $0.isFinite }
                if !visible { continue }   // the context keeps the last invertible matrix; the draws are skipped
                ctx.concatenate(target.concatenating(applied.inverted()))
                applied = target
            case .save:
                ctx.saveGState()
                saves += 1
                stack.append((applied, visible))
            case .restore:
                if saves > 0 {
                    ctx.restoreGState()
                    saves -= 1
                    if let s = stack.popLast() { applied = s.0; visible = s.1 }
                }
            case .clip(let rule, let path):
                if !visible { ctx.clip(to: .zero); continue }
                ctx.addPath(Painter.cgPath(path))
                ctx.clip(using: rule == .evenodd ? .evenOdd : .winding)
            case .fillPath(let rule, let paint, let path):
                if !visible { continue }
                fill(ctx, Painter.cgPath(path), rule: rule, paint: paint)
            case .strokePath(let stroke, let paint, let path):
                if !visible { continue }
                self.stroke(ctx, Painter.cgPath(path), stroke: stroke, paint: paint)
            case .fillText(let t, let paint):
                if !visible { continue }
                drawText(ctx, t, stroke: nil, paint: paint)
            case .strokeText(let t, let stroke, let paint):
                if !visible { continue }
                drawText(ctx, t, stroke: stroke, paint: paint)
            case .drawImage(let surface, let src, let dst, let alpha):
                if !visible { continue }
                guard let img = hooks.image(surface) else { continue }
                drawImage(ctx, img, src: src, dst: dst, alpha: alpha)
            case .clearRect(let r):
                if !visible { continue }
                ctx.clear(CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.w), height: CGFloat(r.h)))
            }
        }
        while saves > 0 { ctx.restoreGState(); saves -= 1 }
        ctx.restoreGState()
    }

    // ---- paths ----------------------------------------------------------------------------------

    /// The CGPath of a draw-list path (user space). An unknown verb ends the path.
    public static func cgPath(_ p: PathData) -> CGPath {
        let path = CGMutablePath()
        let w = p.words
        var i = 0
        loop: while i < w.count {
            let verb = Int32(w[i]); i += 1
            switch PathVerb(rawValue: verb) {
            case .move:
                guard i + 2 <= w.count else { break loop }
                path.move(to: CGPoint(x: CGFloat(w[i]), y: CGFloat(w[i + 1]))); i += 2
            case .line:
                guard i + 2 <= w.count else { break loop }
                path.addLine(to: CGPoint(x: CGFloat(w[i]), y: CGFloat(w[i + 1]))); i += 2
            case .quad:
                guard i + 4 <= w.count else { break loop }
                path.addQuadCurve(to: CGPoint(x: CGFloat(w[i + 2]), y: CGFloat(w[i + 3])), control: CGPoint(x: CGFloat(w[i]), y: CGFloat(w[i + 1]))); i += 4
            case .cubic:
                guard i + 6 <= w.count else { break loop }
                path.addCurve(to: CGPoint(x: CGFloat(w[i + 4]), y: CGFloat(w[i + 5])), control1: CGPoint(x: CGFloat(w[i]), y: CGFloat(w[i + 1])), control2: CGPoint(x: CGFloat(w[i + 2]), y: CGFloat(w[i + 3]))); i += 6
            case .close:
                path.closeSubpath()
            case nil:
                break loop
            }
        }
        return path
    }

    // ---- paints ---------------------------------------------------------------------------------

    /// A draw-list color (times `alpha`) as a CGColor in the painter's sRGB space.
    public static func cgColor(_ c: Color, alpha: Float = 1) -> CGColor {
        let comps: [CGFloat] = [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), CGFloat(max(0, min(1, c.a * alpha)))]
        return CGColor(colorSpace: colorSpace, components: comps) ?? CGColor(red: comps[0], green: comps[1], blue: comps[2], alpha: comps[3])
    }

    private func fill(_ ctx: CGContext, _ path: CGPath, rule: FillRule, paint: PaintData) {
        let cgRule: CGPathFillRule = rule == .evenodd ? .evenOdd : .winding
        if case .solid(let alpha, let color) = paint {
            ctx.setFillColor(Painter.cgColor(color, alpha: alpha))
            ctx.addPath(path)
            ctx.fillPath(using: cgRule)
            return
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: cgRule)
        drawGradient(ctx, paint)
        ctx.restoreGState()
    }

    private func stroke(_ ctx: CGContext, _ path: CGPath, stroke: StrokeData, paint: PaintData) {
        applyStroke(ctx, stroke)
        if case .solid(let alpha, let color) = paint {
            ctx.setStrokeColor(Painter.cgColor(color, alpha: alpha))
            ctx.addPath(path)
            ctx.strokePath()
            return
        }
        // A gradient stroke: the stroked outline (width, caps, joins and the dash honoured) as the clip.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        drawGradient(ctx, paint)
        ctx.restoreGState()
    }

    private func applyStroke(_ ctx: CGContext, _ s: StrokeData) {
        ctx.setLineWidth(CGFloat(s.width))
        switch s.join { case .miter: ctx.setLineJoin(.miter); case .round: ctx.setLineJoin(.round); case .bevel: ctx.setLineJoin(.bevel) }
        switch s.cap { case .butt: ctx.setLineCap(.butt); case .round: ctx.setLineCap(.round); case .square: ctx.setLineCap(.square) }
        ctx.setMiterLimit(CGFloat(s.miterLimit))
        // Canvas2D: a dash list with only zeros (or a negative) is no dash — CG would spin on it.
        let dash = s.dash.map { CGFloat($0) }
        if dash.isEmpty || dash.contains(where: { $0 < 0 || !$0.isFinite }) || !dash.contains(where: { $0 > 0 }) {
            ctx.setLineDash(phase: 0, lengths: [])
        } else {
            ctx.setLineDash(phase: CGFloat(s.dashOffset), lengths: dash)
        }
    }

    /// Draws a gradient paint into the current clip: the clip (already set by the caller) is the
    /// region, the paint's matrix takes the context into GRADIENT space, where the linear axis runs
    /// (0,0) → (1,0) and the radial end circle is the unit circle at the origin (spec/draw.h).
    private func drawGradient(_ ctx: CGContext, _ paint: PaintData) {
        let matrix: Matrix, spread: Spread, stops: [Stop]
        var radial = false
        var fx: Float = 0, fy: Float = 0, r0: Float = 0
        switch paint {
        case .solid: return
        case .linear(_, let m, let s, let st): matrix = m; spread = s; stops = st
        case .radial(_, let m, let x, let y, let r, let s, let st): matrix = m; spread = s; stops = st; radial = true; fx = x; fy = y; r0 = r
        }
        guard !stops.isEmpty else { return }
        let m = CGAffineTransform(a: CGFloat(matrix.a), b: CGFloat(matrix.b), c: CGFloat(matrix.c), d: CGFloat(matrix.d), tx: CGFloat(matrix.e), ty: CGFloat(matrix.f))
        let det = m.a * m.d - m.b * m.c
        guard det != 0, det.isFinite else { return }   // a degenerate gradient paints nothing (Canvas2D)
        ctx.setAlpha(CGFloat(max(0, min(1, paint.alpha))))
        ctx.concatenate(m)
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if radial {
            // The start circle (fx, fy, r0) → the unit end circle; CoreGraphics interpolates circles the
            // Canvas2D way (a real focal point, unlike Android / tgfx). REPEAT / REFLECT continue past
            // the end circle along the same line of circles, out to the clip's farthest corner.
            var periods = 1
            if spread != .pad {
                let box = ctx.boundingBoxOfClipPath
                if !box.isNull, !box.isEmpty {
                    let far = [box.minX, box.maxX].flatMap { x in [box.minY, box.maxY].map { y in hypot(x, y) } }.max() ?? 1
                    periods = max(1, min(64, Int(ceil(far))))
                }
            }
            guard let gradient = Painter.cgGradient(stops, spread: spread, from: 0, to: periods) else { return }
            let k = CGFloat(periods)
            let endCenter = CGPoint(x: CGFloat(fx) * (1 - k), y: CGFloat(fy) * (1 - k))
            let endRadius = CGFloat(r0) + k * (1 - CGFloat(r0))
            ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: CGFloat(fx), y: CGFloat(fy)), startRadius: CGFloat(r0), endCenter: endCenter, endRadius: endRadius, options: options)
        } else {
            var from = 0, to = 1
            if spread != .pad {
                let box = ctx.boundingBoxOfClipPath
                if !box.isNull, !box.isEmpty, box.minX.isFinite, box.maxX.isFinite {
                    from = max(-64, min(0, Int(floor(box.minX))))
                    to = min(64, max(1, Int(ceil(box.maxX))))
                }
            }
            guard let gradient = Painter.cgGradient(stops, spread: spread, from: from, to: to) else { return }
            ctx.drawLinearGradient(gradient, start: CGPoint(x: CGFloat(from), y: 0), end: CGPoint(x: CGFloat(to), y: 0), options: options)
        }
    }

    /// A CGGradient over the gradient-space range [from, to] (integers): the stops as they are for one
    /// period, repeated or mirrored per period for the other spreads.
    static func cgGradient(_ stops: [Stop], spread: Spread, from: Int, to: Int) -> CGGradient? {
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        let span = CGFloat(max(1, to - from))
        if spread == .pad || to - from <= 1 {
            for s in stops { colors.append(cgColor(s.color)); locations.append(CGFloat(s.offset)) }
        } else {
            for k in from..<to {
                let mirrored = spread == .reflect && ((k % 2) + 2) % 2 == 1
                let period = mirrored ? stops.reversed().map { Stop(offset: 1 - $0.offset, color: $0.color) } : stops
                for s in period {
                    colors.append(cgColor(s.color))
                    locations.append((CGFloat(k - from) + CGFloat(s.offset)) / span)
                }
            }
        }
        return CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)
    }

    // ---- text -----------------------------------------------------------------------------------

    private func drawText(_ ctx: CGContext, _ t: TextData, stroke: StrokeData?, paint: PaintData) {
        if t.text.isEmpty { return }
        let font = hooks.font(t.font)
        let line = TextLine(t.text, font: font, letterSpacing: CGFloat(t.letterSpacing))
        // Canvas2D condenses a line wider than maxWidth horizontally, and aligns the CONDENSED box
        // at x (the anchor is kept: a centered line stays centered on x).
        let condense = t.maxWidth > 0 && line.width > CGFloat(t.maxWidth)
        let drawnWidth = condense ? CGFloat(t.maxWidth) : line.width
        let ax = TextLine.alignedX(CGFloat(t.x), width: drawnWidth, align: t.align)
        let by = TextLine.baselineY(CGFloat(t.y), ascent: line.ascent, descent: line.descent, baseline: t.baseline)
        ctx.saveGState()
        if condense {
            ctx.translateBy(x: ax, y: 0)
            ctx.scaleBy(x: CGFloat(t.maxWidth) / line.width, y: 1)
            ctx.translateBy(x: -ax, y: 0)
        }
        if let s = stroke { applyStroke(ctx, s) }
        let mode: CGTextDrawingMode
        switch paint {
        case .solid(let alpha, let color):
            if stroke != nil { ctx.setStrokeColor(Painter.cgColor(color, alpha: alpha)); mode = .stroke }
            else { ctx.setFillColor(Painter.cgColor(color, alpha: alpha)); mode = .fill }
        default:
            mode = stroke != nil ? .strokeClip : .fillClip
        }
        // Glyphs are y-up: flip locally around the baseline origin, draw, flip back (the clip a
        // gradient paint set survives; a restore would drop it).
        ctx.textMatrix = .identity
        ctx.translateBy(x: ax, y: by)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        ctx.setTextDrawingMode(mode)
        // `.fillClip` / `.strokeClip` also paint with the current color; a transparent one leaves
        // only the clip for the gradient below.
        if mode == .fillClip { ctx.setFillColor(Painter.transparent) }
        if mode == .strokeClip { ctx.setStrokeColor(Painter.transparent) }
        CTLineDraw(line.line, ctx)
        if mode == .fillClip || mode == .strokeClip {
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -ax, y: -by)
            drawGradient(ctx, paint)
        }
        ctx.restoreGState()
    }

    // ---- images ---------------------------------------------------------------------------------

    private func drawImage(_ ctx: CGContext, _ img: CGImage, src: Rect4, dst: Rect4, alpha: Float) {
        let srcRect = CGRect(x: CGFloat(src.x), y: CGFloat(src.y), width: CGFloat(src.w), height: CGFloat(src.h))
        let full = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        let cropped: CGImage
        if srcRect == full { cropped = img }
        else {
            guard let c = img.cropping(to: srcRect.intersection(full)) else { return }
            cropped = c
        }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(max(0, min(1, alpha))))
        ctx.interpolationQuality = .high
        // CGContext.draw is y-up: flip around the destination rect so the image lands top-down.
        ctx.translateBy(x: CGFloat(dst.x), y: CGFloat(dst.y) + CGFloat(dst.h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(dst.w), height: CGFloat(dst.h)))
        ctx.restoreGState()
    }
}
