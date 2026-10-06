// The iOS PAINTER host of `_creatorCanvas` (the `HostCanvas` table, canvas.d.ts) — the twin of
// renderers/android's CreatorCanvas.kt. The runtime's AnyCanvas core (engines/canvas) turns the SDK's
// opcode stream and SVG markup into one resolved draw list and keeps the surface registry; this host
// owns the pixels — one CGBitmapContext per surface id the runtime hands out (the painter package's
// Surface: sRGB, premultiplied, its base CTM the y-flip) — and replays the list on it with the
// library's Swift painter (AnyCanvasPainter). The surface feeds the engines' textures (readPixels)
// and `UIImage(canvas)` (the context's CGImage, `surfaceImage`); the same painter draws the SVG
// image nodes (SvgDocuments, the parsed documents by markup).
//
// Every call is synchronous on the JS (= main) thread. Nothing here may throw across the C face: a
// failure logs and leaves the surface as it was.
import AnyCanvasPainter
import CoreGraphics
import CoreText
import LeCodesCore
import UIKit

public final class CreatorCanvas: HostCanvas {
    /// The one painter host of the process (the renderer is one per process too).
    public static let shared = CreatorCanvas()

    /// scale: device px per logical unit (the runtime's paint argument), so the UI draws a retina
    /// canvas at logical size; 1 for a decoded image. `image` caches the context's CGImage until
    /// the next paint (copy-on-write: free until the context is drawn to again).
    private final class Pixels {
        let ctx: CGContext
        var scale: Float
        var image: CGImage?
        init(ctx: CGContext, scale: Float) { self.ctx = ctx; self.scale = scale }
        var cgImage: CGImage? {
            if image == nil { image = ctx.makeImage() }
            return image
        }
    }
    private var surfaces: [Int32: Pixels] = [:]

    /// The UI's font resolution first (a registered font draws canvas text like it draws UI text),
    /// the platform's own for anything else; the images of the surfaces for DRAW_IMAGE.
    private struct Hooks: PainterHooks {
        unowned let host: CreatorCanvas
        func font(_ f: FontData) -> CTFont {
            if let ui = FontManager.registeredFont(family: f.family, weight: Int(f.weight), italic: f.italic, size: CGFloat(f.size)) { return ui as CTFont }
            return Fonts.resolve(f)
        }
        func image(_ surface: Int32) -> CGImage? { host.surfaces[surface]?.cgImage }
    }
    /// The one painter of this renderer: canvas surfaces and the SVG image nodes.
    public private(set) lazy var painter = Painter(hooks: Hooks(host: self))

    private init() {}

    // MARK: - HostCanvas

    /// Replay the draw list into surface `surfaceId` (pw × ph device px), created on its first paint
    /// and recreated on a size change. The list is already in device px: the core folded `scale` in.
    public func paint(surfaceId: Int32, pw: Int32, ph: Int32, scale: Float, words: UnsafeBufferPointer<Float>, strings: [String]) {
        let w = Int(max(pw, 1)), h = Int(max(ph, 1))
        var s: Pixels? = surfaces[surfaceId]
        if s == nil || s!.ctx.width != w || s!.ctx.height != h {
            // A new context on a size change: an image node reads identity as "the intrinsic size
            // changed" (refreshCanvasSurface).
            guard let ctx = Surface.makeContext(width: w, height: h) else { print("[CreatorCanvas] paint(\(surfaceId)): no context for \(w)×\(h)"); return }
            s = Pixels(ctx: ctx, scale: scale)
            surfaces[surfaceId] = s
        }
        guard let surface = s else { return }
        surface.scale = scale
        surface.image = nil
        Surface.clear(surface.ctx)
        do {
            try painter.paint(surface.ctx, DrawList(words: Array(words), strings: strings))
        } catch {
            print("[CreatorCanvas] paint(\(surfaceId)) failed: \(error)")
        }
    }

    /// out[3] = width, ascent, descent (logical px, both positive) — the SAME CTLine the painter
    /// draws with, so a measure and a painted width agree.
    public func measureText(text: String, family: String, size: Float, weight: Int32, italic: Bool, out: UnsafeMutablePointer<Float>) {
        let font = painter.hooks.font(FontData(family: family, size: size, weight: weight, italic: italic))
        let line = TextLine(text, font: font)
        out[0] = Float(line.width)
        out[1] = Float(line.ascent)
        out[2] = Float(line.descent)
    }

    /// The encoded bytes of host buffer `bufferId` into the NEW surface `surfaceId` (an id the runtime
    /// reserved); its pixel size to size[2]. SVG never reaches this slot: the runtime sniffs it.
    public func decodeImage(bufferId: Int32, surfaceId: Int32, size: UnsafeMutablePointer<Int32>) -> Bool {
        guard let data = rendererServices?.buffer(id: Int(bufferId)), let image = UIImage(data: data)?.cgImage else { return false }
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = Surface.makeContext(width: w, height: h) else { return false }
        // The context's base CTM is the y-flip for the y-down lists; a CGImage draws y-up — undo it
        // for the blit, or the image lands upside down.
        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted())
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
        surfaces[surfaceId] = Pixels(ctx: ctx, scale: 1)
        size[0] = Int32(w)
        size[1] = Int32(h)
        return true
    }

    /// Straight RGBA8, top row first; w × h in size[2]. Nil for an unknown surface.
    public func readPixels(surfaceId: Int32, size: UnsafeMutablePointer<Int32>) -> [UInt8]? {
        guard let s = surfaces[surfaceId] else { return nil }
        size[0] = Int32(s.ctx.width)
        size[1] = Int32(s.ctx.height)
        return Surface.straightRGBA(s.ctx)
    }

    public func releaseSurface(surfaceId: Int32) {
        surfaces.removeValue(forKey: surfaceId)
        CanvasSurfaces.remove(surfaceId)
    }

    // MARK: - UIImage(canvas) support, teardown

    /// The painted surface for an image node to show: its pixels (the cached CGImage) and the
    /// device-px-per-logical scale (so the UI draws a retina canvas at logical size).
    public func surfaceImage(_ surfaceId: Int32) -> (image: CGImage, scale: CGFloat)? {
        guard let s = surfaces[surfaceId], let image = s.cgImage else { return nil }
        return (image, CGFloat(s.scale > 0 ? s.scale : 1))
    }

    /// Project switch / engine dispose: every surface and every parsed SVG document goes (the
    /// runtime releases owned surfaces itself; this is the belt to that suspender).
    public func clearAll() {
        surfaces.removeAll()
        SvgDocuments.clear()
    }
}

/// The image nodes showing a canvas surface, by surface id — `Canvas.update()` re-rasterizes the
/// surface in place and the runtime's `_creatorTree.refreshCanvasSurface` callback (the host
/// registers it) repaints them without a `src` round-trip. Weak: a node leaves with itself.
public enum CanvasSurfaces {
    private struct Weak { weak var node: UINodeImage? }
    private static var buckets: [Int32: [ObjectIdentifier: Weak]] = [:]

    static func register(_ surfaceId: Int32, _ node: UINodeImage) {
        buckets[surfaceId, default: [:]][ObjectIdentifier(node)] = Weak(node: node)
    }
    static func unregister(_ surfaceId: Int32, _ node: UINodeImage) {
        buckets[surfaceId]?[ObjectIdentifier(node)] = nil
    }
    /// One call per `Canvas.update()` on a UI-bound canvas — per update, not per frame.
    public static func refresh(_ surfaceId: Int32) {
        guard let bucket = buckets[surfaceId] else { return }
        let nodes = bucket.values.compactMap { $0.node }
        if nodes.isEmpty { buckets[surfaceId] = nil; return }
        for node in nodes { node.refreshCanvasSurface(surfaceId) }
    }
    /// The surface was released (ids are never reused): its bucket can go now.
    static func remove(_ surfaceId: Int32) { buckets[surfaceId] = nil }
}

/// Parsed SVG documents for the image nodes' `svg:` sources, keyed by their markup and shared by
/// every node that shows the same one (a list of rows with one icon parses it once); the parser is
/// the runtime's own AnyCanvas core (LeCodesCore.SvgDocument). A node holds only the markup and asks
/// here whenever it needs a new draw list (a size or tint change) — no native handle lives in a
/// node, so none leaks with one. Least recently used out when full. Main thread only.
enum SvgDocuments {
    private static let capacity = 64
    private static var cache: [String: SvgDocument] = [:]
    private static var order: [String] = []   // most recently used last

    /// The parsed document, nil when the core rejects the markup (or it has no size).
    static func get(_ markup: String) -> SvgDocument? {
        if let doc = cache[markup] {
            if order.last != markup, let i = order.firstIndex(of: markup) { order.remove(at: i); order.append(markup) }
            return doc
        }
        guard let doc = SvgDocument(markup: markup) else { return nil }
        cache[markup] = doc
        order.append(markup)
        if order.count > capacity { cache[order.removeFirst()] = nil }
        return doc
    }

    static func clear() {
        cache.removeAll()
        order.removeAll()
    }
}
