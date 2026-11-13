// The image node's view — the old host's NodeImage (a UIImageView), lifted for every source: a URL
// through ImageLoader, a host buffer (`id:<n>`, an SVG file sniffed and drawn as markup), SVG markup
// (`svg:`, the core parses it once per distinct markup — SvgDocuments — and the AnyCanvas painter
// renders its draw list into a bitmap of the view's pixel size, re-rendered on a size or tint change),
// a canvas surface (`canvas:<id>`, the painter host's CGImage, re-read on Canvas.update()); a LIVE
// 2D scene (`scene2d:<id>`: the engine draws it into an IOSurface under this view every frame —
// Scene2DImages — the box IS the render size, no intrinsic size). objectFit as contentMode, the atlas crop
// (`sourceRect`) as layer.contentsRect — UIImageView RESETS contentsRect whenever `image` is
// assigned, so the crop is re-applied after every load and in layoutSubviews; the rect is in texture
// pixels, exempt from density. A raster image carries scale 1 (UIImage(data:)), so `image.size` is
// its pixel size — the intrinsic size the measure uses; a canvas surface carries its device scale, so
// it measures at logical size; an SVG measures at its natural size.
//
// A URL comes in two steps (ImageLoader, the twin of the Android renderer's): its bytes and its size
// first — all the measure needs (`naturalSize`) — and its pixels when the view has a box, decoded DOWN
// to that box (`ensurePixels`, from layoutSubviews). A photo from a camera is 12 MP: 48 MB of pixels
// as it is stored, a quarter of that in a feed's row, a few hundred KB as an avatar.
//
// The PREVIEW (the node's "preview" prop: UIImage.preview) is a second picture, drawn in the box while
// the node's own is not there — on its way, or failed: a subview under everything else the view
// draws, placed by the node's objectFit alone, gone the moment `image` is set (syncPreview). It is
// loaded by the node (UINodeImage.previewBitmap), sizes nothing and reports nothing.
//
// An image inside a text (an icon in a line, docs/plans/rich-text-plan.md rules 9–15) has no view:
// InlineImage below loads its source through the same pieces (ImageSourceKind, SvgDocuments.bitmap,
// ImageLoader) for the paragraph's label to draw.
import AnyCanvasPainter
import ImageIO
import LeCodesCore
import UIKit

final class ImageView: UIImageView {
    weak var node: UINodeImage?
    /// Texture px. A crop is decoded whole: a change asks for a layout pass, whose ensurePixels
    /// decodes again when what is shown was halved for the box.
    var sourceRect: CGRect? { didSet { if sourceRect != oldValue { setNeedsLayout() } } }
    private var loadToken: ImageLoader.Token?
    /// A URL's image as it came (bytes + size), the size the measure uses for it, and how far the
    /// pixels shown are a halving of it (0 = `image` is not a URL's). `sourceGeneration` tells an
    /// answer for a source the view has left since.
    private var source: ImageLoader.Source?
    private var naturalSize: CGSize?
    private var imageSample = 0
    private var decodingSample = 0
    private var sourceGeneration = 0
    /// The SVG document shown (SvgDocuments owns it), and what the bitmap was last rendered for.
    private var svg: SvgDocument?
    private var svgTint: UInt32?
    private var svgRendered: (size: CGSize, tint: UInt32?)?
    /// The canvas surface bound (a later Canvas.update() repaints in place).
    private(set) var canvasSurfaceId: Int32?
    /// The live 2D scene shown (Scene2DImages draws it under this view every frame).
    private(set) var scene2dId: Int32?
    /// The node's objectFit as it was set: what places the preview, whatever a crop made of `contentMode`.
    private var fit: CuiPaint.ObjectFit = .contain
    /// The preview standing in the box (syncPreview); nil while the node's own picture is there.
    private var previewView: UIImageView?

    /// The node's picture came or went: the preview gives way to it, or stands in again.
    override var image: UIImage? { didSet { syncPreview() } }

    init(node: UINodeImage) {
        self.node = node
        super.init(frame: .zero)
        clipsToBounds = true
        contentMode = .scaleAspectFit
        isUserInteractionEnabled = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// A touch that landed on the image and is held by a target above ends with the view (HeldTouches).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { HeldTouches.viewLeftWindow(self) }
    }

    func setObjectFit(_ fit: CuiPaint.ObjectFit) {
        self.fit = fit
        if previewView != nil { setNeedsLayout() }
        guard sourceRect == nil else { return }   // an active crop always fills the box
        switch fit {
        case .cover: contentMode = .scaleAspectFill
        case .contain: contentMode = .scaleAspectFit
        case .fill: contentMode = .scaleToFill
        }
    }

    /// A raster source: nil clears. Cancels a load in flight (a URL still loading must not land
    /// over a buffer that arrived after it); drops an SVG.
    func setImage(_ image: UIImage?, remeasure: Bool = true) {
        loadToken?.cancel()
        loadToken = nil
        dropSource()
        svg = nil
        svgRendered = nil
        self.image = image
        applySourceRectCrop()
        if remeasure { node.map { FrameBatcher.request($0, measure: true) } }
    }

    /// SVG markup: the document parsed by the core (nil = markup it rejects draws nothing, like an
    /// image that does not decode); the bitmap is rendered at the view's pixel size in layoutSubviews.
    func setSvg(_ markup: String?) {
        loadToken?.cancel()
        loadToken = nil
        dropSource()
        image = nil
        svgRendered = nil
        svg = markup.flatMap { SvgDocuments.get($0) }
        if markup != nil, svg == nil { print("[ImageView] SVG source did not parse (\(markup!.count) chars)") }
        node.map { FrameBatcher.request($0, measure: true) }
        setNeedsLayout()
    }

    /// The one tint (the core's cascade): SVG only — a re-render, no re-measure.
    func setTint(_ tint: UInt32?) {
        guard svgTint != tint else { return }
        svgTint = tint
        if svg != nil || previewView != nil { setNeedsLayout() }
    }

    /// The preview (the node's "preview" prop) stands in the box while the node's own picture is not
    /// there to draw — a url on its way or failed, bytes no codec reads, no src — and gives way the
    /// moment it is: `image` set (a URL's pixels, a buffer, a canvas surface), an SVG parsed (drawn at
    /// the next layout). A live scene has no picture to wait for. It is asked for only here, with a
    /// box (UINodeImage.previewBitmap: nothing is loaded for a picture that is already there), drawn
    /// with the node's objectFit — never its `sourceRect`, a crop of the picture's own pixels — under
    /// the view's corner clip, and it sizes nothing: `measure` never reads it.
    func syncPreview() {
        guard let node, !node.isRun else { return hidePreview() }   // a run's preview is its paragraph's to draw
        guard image == nil, svg == nil, scene2dId == nil, canvasSurfaceId == nil, node.hasPreview else {
            hidePreview()
            node.dropPreview()
            return
        }
        guard let bitmap = node.previewBitmap(in: bounds.size, fit: fit)?.bitmap else { previewView?.image = nil; return }
        let v: UIImageView
        if let previewView { v = previewView } else {
            v = UIImageView()
            v.clipsToBounds = true
            v.isUserInteractionEnabled = false
            insertSubview(v, at: 0)
            previewView = v
        }
        v.frame = bounds
        switch fit {
        case .cover: v.contentMode = .scaleAspectFill
        case .contain: v.contentMode = .scaleAspectFit
        case .fill: v.contentMode = .scaleToFill
        }
        if v.image !== bitmap { v.image = bitmap }
    }
    private func hidePreview() {
        previewView?.removeFromSuperview()
        previewView = nil
    }

    /// The SVG's bitmap for the current bounds and tint: the core's draw list aspect-fitted into the
    /// view's pixel box (letterboxed transparent), the painter's replay into a Surface context.
    private func renderSvgIfNeeded() {
        guard let svg else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if let r = svgRendered, r.size == size, r.tint == svgTint { return }
        guard let bitmap = SvgDocuments.bitmap(svg, size: size, tint: svgTint) else { return }
        svgRendered = (size, svgTint)
        image = bitmap
        if sourceRect != nil { applySourceRectCrop() }
    }

    /// A canvas surface (`canvas:<id>`): the painter host's pixels at their device scale, bound so a
    /// later Canvas.update() repaints this view in place.
    func setCanvas(_ surfaceId: Int32) {
        if let prev = canvasSurfaceId, prev != surfaceId, let node { CanvasSurfaces.unregister(prev, node) }
        canvasSurfaceId = surfaceId
        if let node { CanvasSurfaces.register(surfaceId, node) }
        setImage(canvasImage(surfaceId))
    }
    private func canvasImage(_ surfaceId: Int32) -> UIImage? {
        CreatorCanvas.shared.surfaceImage(surfaceId).map { UIImage(cgImage: $0.image, scale: $0.scale, orientation: .up) }
    }
    /// Every other source drops the binding.
    func unbindCanvas() {
        guard let prev = canvasSurfaceId else { return }
        canvasSurfaceId = nil
        if let node { CanvasSurfaces.unregister(prev, node) }
    }
    /// Canvas.update(): the surface was re-rasterized under the same id — re-read it; a size change
    /// is a re-measure, the animated hot path a repaint only.
    func refreshCanvasSurface(_ surfaceId: Int32) {
        guard canvasSurfaceId == surfaceId, let next = canvasImage(surfaceId) else { return }
        let resized = image.map { $0.size != next.size } ?? true
        setImage(next, remeasure: resized)
    }

    /// A live 2D scene (`scene2d:<id>`): nothing to decode, the engine draws into a sublayer sized
    /// to the box every frame; the node has no intrinsic size (the box is the render size).
    func setScene2d(_ sceneId: Int32) {
        setImage(nil, remeasure: false)
        scene2dId = sceneId
        if let node { Scene2DImages.attach(node, sceneId: sceneId) }
        node.map { FrameBatcher.request($0, measure: true) }
    }
    /// Every other source drops the scene.
    func unbindScene2d() {
        guard scene2dId != nil else { return }
        scene2dId = nil
        if let node { Scene2DImages.detach(node) }
    }

    /// A URL: the bytes and the size now — here at once when the url was loaded before, so a vlist
    /// row drawn again keeps its picture — the pixels at the first layout with a box (ensurePixels).
    /// What the view showed stays until then. `cache` is the device cache's mode of the node
    /// (docs/cache.md). The request the view waited on is let go AFTER the new one is asked for:
    /// the same url asked again in another mode joins the load under way instead of ending it.
    func load(url: String, cache: String = "") {
        let previous = loadToken
        loadToken = nil
        svg = nil
        svgRendered = nil
        // the answer below belongs to THIS request (the generation is taken after the bump)
        source = nil
        imageSample = 0
        decodingSample = 0
        sourceGeneration += 1
        let generation = sourceGeneration
        loadToken = ImageLoader.load(url, cache: cache, shown: { [weak self] in self?.isShownOnScreen ?? false }) { [weak self] loaded in
            guard let self, self.sourceGeneration == generation, self.node?.isRemoved == false else { return }
            self.loadToken = nil
            // TREE_EVENT_IMAGE: the url's answer is the picture's — its own size (the header's), or none
            self.node?.imageSettled(loaded.map { CGSize(width: $0.width, height: $0.height) })
            guard let loaded else {
                // nothing came, or what came is no image: the node shows nothing, as before
                self.naturalSize = nil
                self.image = nil
                self.applySourceRectCrop()
                self.node.map { FrameBatcher.request($0, measure: true) }
                return
            }
            self.source = loaded
            self.naturalSize = CGSize(width: loaded.width, height: loaded.height)
            self.node.map { FrameBatcher.request($0, measure: true) }
            // a box the layout does not move (an explicit size) gets no layoutSubviews of its own
            self.setNeedsLayout()
            self.ensurePixels()
        }
        previous?.cancel()
        // With a preview, the box shows IT while the new picture is on its way — not the picture of
        // the src the node has left.
        if imageSample == 0, image != nil, node?.hasPreview == true {
            image = nil
            applySourceRectCrop()
        }
    }

    /// Any other source: what a URL left behind is dropped.
    private func dropSource() {
        source = nil
        naturalSize = nil
        imageSample = 0
        decodingSample = 0
        sourceGeneration += 1
    }

    /// The pixels for the view's box: decoded when the view has none of this source, or too few for
    /// the box (it grew past what was decoded). A picture cut by `sourceRect` is decoded whole — the
    /// rect is in the picture's own pixels.
    private func ensurePixels() {
        guard let source else { return }
        let scale = UIScreen.main.scale
        let boxWidth = Int((bounds.width * scale).rounded(.up)), boxHeight = Int((bounds.height * scale).rounded(.up))
        guard boxWidth > 0, boxHeight > 0 else { return }
        let want = sourceRect != nil ? 1 : ImageLoader.sampleFor(source, boxWidth: boxWidth, boxHeight: boxHeight)
        if imageSample >= 1, imageSample <= want { return }
        if decodingSample == want { return }
        decodingSample = want
        let generation = sourceGeneration
        ImageLoader.decode(source, sample: want) { [weak self] decoded in
            guard let self, self.sourceGeneration == generation, self.node?.isRemoved == false else { return }
            if self.decodingSample == want { self.decodingSample = 0 }
            guard let decoded else { return }
            // A coarser decode asked for before the box grew, landing after the finer one: the finer stays.
            if self.imageSample >= 1, self.imageSample < want { return }
            self.image = decoded
            self.imageSample = want
            self.applySourceRectCrop()
        }
    }

    func cancelLoad() {
        loadToken?.cancel()
        loadToken = nil
    }

    func applySourceRectCrop() {
        guard let r = sourceRect, let image, image.size.width > 0, image.size.height > 0 else {
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        // the rect is in the picture's own pixels: a URL's natural size, whatever it was decoded down to
        let nw = naturalSize?.width ?? image.size.width * image.scale, nh = naturalSize?.height ?? image.size.height * image.scale
        layer.contentsRect = CGRect(x: r.origin.x / nw, y: r.origin.y / nh, width: r.width / nw, height: r.height / nh)
        contentMode = .scaleToFill
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        node?.box.layoutSublayers()
        ensurePixels()
        renderSvgIfNeeded()
        if sourceRect != nil { applySourceRectCrop() }
        syncPreview()   // after the two above: a picture that is here already leaves nothing to stand in for
    }

    /// The box's shadow lives in the parent's layer: it goes where the view goes (BoxShadow.swift).
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        node?.followShadow()
    }

    /// The yoga measure: the intrinsic size fitted into the constraints, never upscaled unless a
    /// dimension is exact. 0 = no intrinsic size yet (the load lands as a re-measure).
    func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        let base: CGSize
        if scene2dId != nil { return .zero }   // the box is the render size
        if let r = sourceRect { base = r.size }
        else if let svg { base = CGSize(width: CGFloat(svg.width), height: CGFloat(svg.height)) }
        else if let naturalSize { base = naturalSize }   // a URL's own size: known before its pixels, kept when they are decoded smaller
        else if let image { base = image.size }   // points: a raster's pixels, a canvas surface's logical size
        else { return .zero }
        guard base.width > 0, base.height > 0 else { return .zero }
        let wN = widthMode == 0 || width.isNaN ? CGFloat.greatestFiniteMagnitude : CGFloat(width)
        let hN = heightMode == 0 || height.isNaN ? CGFloat.greatestFiniteMagnitude : CGFloat(height)
        var k = min(wN / base.width, hN / base.height)
        if widthMode != 1, heightMode != 1 { k = min(k, 1) }
        return CGSize(width: base.width * k, height: base.height * k)
    }
}

extension UIView {
    /// Is any of the view's box in what the screen shows now: inside the viewport of every scroll
    /// view above it (a scrollable, a pager, a list — the views that clip whatever `overflow` says)
    /// and inside the window; under the app root where there is no window (a test's root). What
    /// orders the images that wait to be loaded (ImageLoader). Main thread.
    var isShownOnScreen: Bool {
        guard window != nil || UINode.appRoot.map({ isDescendant(of: $0) }) == true else { return false }
        var rect = bounds
        var view: UIView = self
        while true {
            guard !view.isHidden, !rect.isEmpty else { return false }
            guard let parent = view.superview else { return true }
            // a scroll view's bounds start at its offset: the rect lands in what it shows
            rect = view.convert(rect, to: parent)
            if parent is UIScrollView || parent.superview == nil { rect = rect.intersection(parent.bounds) }
            view = parent
        }
    }
}

/// What an image `src` names — the ONE reading of its wire spellings (sdk/src/ui/UIImage.ts), shared
/// by the image view and an image run: a canvas surface (`canvas:<id>`, nil = malformed), a live 2D
/// scene (`scene2d:<id>`), SVG markup (`svg:`, or a host buffer `id:<n>` that sniffs as an SVG file —
/// the runtime's rule for canvas images), a raster buffer (`id:<n>`, nil = it does not decode), a URL,
/// or nothing ("").
enum ImageSourceKind {
    case none
    case canvas(Int32?)
    case scene2d(Int32?)
    case svg(String)
    case raster(UIImage?)
    case url(String)

    static func of(_ src: String) -> ImageSourceKind {
        if src.hasPrefix("canvas:") { return .canvas(Int32(src.dropFirst(7))) }
        if src.hasPrefix("scene2d:") { return .scene2d(Int32(src.dropFirst(8))) }
        if src.isEmpty { return .none }
        if src.hasPrefix("id:") {
            let data = Int(src.dropFirst(3)).flatMap { rendererServices?.buffer(id: $0) }
            if let data, SvgDocument.looksLikeSvg(data) { return .svg(String(decoding: data, as: UTF8.self)) }
            return .raster(data.flatMap { UIImage(data: $0) })
        }
        if src.hasPrefix("svg:") { return .svg(String(src.dropFirst(4))) }
        return .url(src)
    }

    /// `src` is a URL — the same reading as `of`, without touching the source (an `id:` buffer is
    /// decoded there).
    static func isUrl(_ src: String) -> Bool {
        !src.isEmpty && !["canvas:", "scene2d:", "id:", "svg:"].contains { src.hasPrefix($0) }
    }
}

extension SvgDocuments {
    /// `svg`'s bitmap for a box of `size` points at the screen's scale: the core's draw list
    /// aspect-fitted into the pixel box (letterboxed transparent), `tint` applied, replayed by the
    /// AnyCanvas painter. nil when the box is empty or the painter fails.
    static func bitmap(_ svg: SvgDocument, size: CGSize, tint: UInt32?) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = UIScreen.main.scale
        let pw = Int((size.width * scale).rounded(.up)), ph = Int((size.height * scale).rounded(.up))
        guard let ctx = Surface.makeContext(width: pw, height: ph) else { return nil }
        let list = svg.draw(width: Float(pw), height: Float(ph), tint: tint)
        do {
            try CreatorCanvas.shared.painter.paint(ctx, DrawList(words: list.words, strings: list.strings))
        } catch {
            print("[ImageView] SVG draw list failed: \(error)")
            return nil
        }
        return ctx.makeImage().map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
    }
}

/// The bitmap of an IMAGE RUN — an icon in a line (docs/plans/rich-text-plan.md rules 9–12). An image
/// inside a text has no view (its paragraph's label lays it out and draws it), so its source loads
/// here, through the image view's own pieces: the same reading of the src (ImageSourceKind), the same
/// documents (SvgDocuments: rendered for the box and the tint), the same loader (ImageLoader: the
/// bytes and the size, then the pixels decoded down to the box). Only an image source draws in a
/// line (rule 15): a canvas surface or a live scene keeps its box reserved and empty, as an image
/// that has not arrived. `changed(sizeMoved)` tells the run's node later: the source's own size
/// arrived (its aspect may size the box — the paragraph re-measures), or its pixels did (a redraw);
/// an answer inside a call of this class is no change (the caller collects next). `settled` hears
/// what TREE_EVENT_IMAGE reports of a source — its own size once it is known, nil when it will not
/// be — also inside a call. The node's PREVIEW is loaded by one of these too, for a block as for a
/// run (UINodeImage.previewBitmap), with no `settled`: a preview reports nothing. Main thread.
final class InlineImage {
    var settled: ((CGSize?) -> Void)?
    /// The source's own size (an svg's, a raster's, a URL's header size), nil until known: the
    /// aspect a box with one side set takes (rule 10).
    private(set) var naturalSize: CGSize?
    private let changed: (_ sizeMoved: Bool) -> Void
    /// Is the run's paragraph on the screen now: what orders a URL that waits to be loaded (ImageLoader).
    private let shown: () -> Bool
    private var svg: SvgDocument?
    private var rendered: (size: CGSize, tint: UInt32?, image: UIImage)?
    /// A raster buffer's image, or a URL's pixels as decoded (by `sample` halvings).
    private var raster: UIImage?
    private var source: ImageLoader.Source?
    private var loadToken: ImageLoader.Token?
    private var sample = 0
    private var decodingSample = 0
    /// Bumped by every source and cancel: an answer for a source left since is dropped.
    private var generation = 0
    private var inCall = false

    init(shown: @escaping () -> Bool, changed: @escaping (_ sizeMoved: Bool) -> Void) {
        self.shown = shown
        self.changed = changed
    }

    /// `cache`: the device cache's mode of a URL (docs/cache.md). As ImageView.load, the request
    /// waited on is let go after the new one is asked for.
    func setSource(_ src: String, cache: String = "") {
        let previous = loadToken
        loadToken = nil
        generation += 1
        defer { previous?.cancel() }
        svg = nil
        rendered = nil
        raster = nil
        source = nil
        naturalSize = nil
        sample = 0
        decodingSample = 0
        inCall = true
        defer { inCall = false }
        switch ImageSourceKind.of(src) {
        case .svg(let markup):
            svg = SvgDocuments.get(markup)
            if svg == nil { print("[InlineImage] SVG source did not parse (\(markup.count) chars)") }
            naturalSize = svg.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) }
            settled?(naturalSize)
        case .raster(let image):
            raster = image
            naturalSize = image?.size
            settled?(image.map { CGSize(width: $0.size.width * $0.scale, height: $0.size.height * $0.scale) })
        case .url(let url):
            let generation = generation
            loadToken = ImageLoader.load(url, cache: cache, shown: shown) { [weak self] loaded in
                guard let self, self.generation == generation else { return }
                self.loadToken = nil
                self.settled?(loaded.map { CGSize(width: $0.width, height: $0.height) })
                guard let loaded else { return }   // nothing came, or no image: the box stays empty
                self.source = loaded
                self.naturalSize = CGSize(width: loaded.width, height: loaded.height)
                if !self.inCall { self.changed(true) }
            }
        case .none, .canvas, .scene2d:
            break
        }
    }

    func cancel() {
        generation += 1
        loadToken?.cancel()
        loadToken = nil
    }

    /// The pixels of the WHOLE picture drawn `size` points large (`place`: the box clips it), `tint`
    /// on an svg: an svg rendered at that size, a URL's pixels decoded down to it (asked here, drawn
    /// when they land); nil = nothing to draw yet (the box stays reserved).
    func bitmap(for size: CGSize, tint: UInt32?) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        if let svg {
            if let r = rendered, r.size == size, r.tint == tint { return r.image }
            guard let image = SvgDocuments.bitmap(svg, size: size, tint: tint) else { return nil }
            rendered = (size, tint, image)
            return image
        }
        if let source {
            inCall = true
            ensurePixels(source, size: size)
            inCall = false
        }
        return raster
    }

    private func ensurePixels(_ source: ImageLoader.Source, size: CGSize) {
        let scale = UIScreen.main.scale
        let want = ImageLoader.sampleFor(source, boxWidth: Int((size.width * scale).rounded(.up)), boxHeight: Int((size.height * scale).rounded(.up)))
        if sample >= 1, sample <= want { return }
        if decodingSample == want { return }
        decodingSample = want
        let generation = generation
        ImageLoader.decode(source, sample: want) { [weak self] decoded in
            guard let self, self.generation == generation else { return }
            if self.decodingSample == want { self.decodingSample = 0 }
            guard let decoded else { return }
            if self.sample >= 1, self.sample < want { return }   // a finer decode landed first: it stays
            self.raster = decoded
            self.sample = want
            if !self.inCall { self.changed(false) }
        }
    }

    /// Where a picture of `natural` size lands in a box of `box` (its origin at 0, 0), as an image
    /// node shows it: an atlas crop (`crop`, in the picture's own units) stretched over the box,
    /// else the objectFit — cover / contain centred, fill stretched. The box clips what overflows.
    static func place(_ natural: CGSize, crop: CGRect?, fit: CuiPaint.ObjectFit, in box: CGSize) -> CGRect {
        guard natural.width > 0, natural.height > 0 else { return CGRect(origin: .zero, size: box) }
        if let crop, crop.width > 0, crop.height > 0 {
            let sx = box.width / crop.width, sy = box.height / crop.height
            return CGRect(x: -crop.minX * sx, y: -crop.minY * sy, width: natural.width * sx, height: natural.height * sy)
        }
        let sx: CGFloat, sy: CGFloat
        switch fit {
        case .cover: sx = max(box.width / natural.width, box.height / natural.height); sy = sx
        case .contain: sx = min(box.width / natural.width, box.height / natural.height); sy = sx
        case .fill: sx = box.width / natural.width; sy = box.height / natural.height
        }
        let w = natural.width * sx, h = natural.height * sy
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }
}

/// The images of a url, in two steps — because what an image costs is its PIXELS, and how many of
/// them are needed is known only where it is shown (the twin of the Android renderer's ImageLoader):
///
///  1. `load` — the BYTES, at once, and what their header says: the size the picture has as it is
///     shown. That is all a layout needs.
///  2. `decode` — the PIXELS, when the box is known (`sampleFor`): a picture is decoded by whole
///     halvings down to the box it is drawn in, and never larger than the screen. ImageIO makes
///     them at that size (it never holds the full frame) and applies the camera's Exif turn.
///
/// Both steps keep what they made (sources by url, decoded images by url + halving), share one piece
/// of work among the views that ask for the same thing, and answer IN THE CALL when it is already
/// there. A decoded image carries the scale that makes `image.size` the picture's own size, so what
/// reads it (a tiled background's cell) is not told of the halving.
///
/// A url may be asked for again while its cancelled request is still on its way out (the old image
/// view of a row goes, the new one asks for the same url): a request settles ITS OWN slot and no
/// other — the late completion of a cancelled one must not answer, or clear, the request that
/// followed it.
///
/// The device cache (docs/cache.md). The bytes come through the host (RendererServices.fetch) in
/// the mode the asker names — the host's one function carries it out, so an image's copy and a
/// fetch's are the same one. A load is shared, so it is made in its FIRST asker's mode, and an
/// asker that joins is owed what its own mode promises (the desktop's rule: `urlBytes`,
/// hosts/desktop/src/host/resources.cpp):
///
///  - a copy KEPT: `kept` holds the urls whose copy is kept, or will be by the load under way. An
///    asker that keeps one when the load did not has it written from the bytes
///    (RendererServices.keepCopy) — at once when they are here, when they land otherwise;
///  - the copy READ: when the load brings no answer and an asker that joined named a mode that
///    reads the copy, the url is asked for once more, in that mode, for every waiter.
///
/// An image node is such an asker of its own load: its `cache` arrives after its `src`
/// (UINodeImage.setProperty).
///
/// Order: at most `maxActive` requests are with the host at a time; the others wait here, and a
/// slot that frees goes to a url SHOWN NOW — one of its askers says its box is on the screen
/// (`load`'s `shown`, asked at that moment: the screen may have scrolled since the url was asked for)
/// — before the ones nobody sees yet, which follow in the order they were asked. Nothing is dropped:
/// an image off the screen is still loaded (its size is its layout's), after the ones in view.
/// URLSession orders nothing itself: over HTTP/1.1 its tasks wait in the order they were made,
/// over HTTP/2 they all share the line.
///
/// Main thread: every call and every answer; the bytes are fetched by the host and the pixels
/// decoded on a queue of this type.
public enum ImageLoader {
    /// An image as it came: its bytes, and its size AS IT IS SHOWN (a camera's quarter turn applied).
    public final class Source {
        public let url: String
        public let width: Int
        public let height: Int
        fileprivate let data: Data
        /// The bytes are the body of a 200: what the device cache keeps.
        fileprivate let keepable: Bool
        /// The longer side of the frame as it is stored.
        fileprivate let side: Int
        fileprivate init(url: String, data: Data, width: Int, height: Int, keepable: Bool) {
            self.url = url
            self.data = data
            self.keepable = keepable
            self.width = width
            self.height = height
            self.side = max(width, height)
        }
    }

    public final class Token {
        fileprivate let url: String
        fileprivate let id = UUID()
        /// The request this token waits on (a later one for the same url is not its to cancel).
        fileprivate weak var request: Request?
        fileprivate var inner: Token?
        fileprivate(set) var isCancelled = false
        fileprivate init(url: String) { self.url = url }
        public func cancel() {
            isCancelled = true
            inner?.cancel()
            ImageLoader.cancel(self)
        }
    }

    private static let sources: NSCache<NSString, Source> = { let c = NSCache<NSString, Source>(); c.totalCostLimit = 24 * 1024 * 1024; return c }()
    /// Decoded pixels kept for the next view that shows them: a sixteenth of the device's memory, 32 MB at least.
    private static let images: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = max(32 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 16))
        return c
    }()
    private static var waiters: [String: [UUID: (Source?) -> Void]] = [:]
    /// A url's bytes on their way: one request for every asker of the url.
    fileprivate final class Request {
        let url: String
        /// The mode the request under way was made in: the first asker's.
        var mode: String
        /// A mode an asker that joined named, which reads a copy the request's own does not.
        var later: String?
        var handle: Cancel?
        /// Which of this load's requests is under way: an answer says whose it is.
        var attempt = 0
        /// With the host (a slot taken) — and no longer: its slot is given back once.
        var started = false
        var ended = false
        /// The askers' "is my box on the screen now", by token — what orders the requests that wait.
        var shown: [UUID: () -> Bool] = [:]
        init(url: String, mode: String) {
            self.url = url
            self.mode = mode
        }
    }
    /// Every request asked for and not settled: with the host, or waiting in `waiting`.
    private static var requests: [String: Request] = [:]
    /// How many requests are with the host at a time. URLSession opens 4 connections per server
    /// over HTTP/1.1 and has no limit of its own over HTTP/2: what waits past these waits HERE,
    /// where it can be ordered.
    static let maxActive = 6
    private static var active = 0
    private static var waiting: [Request] = []
    /// The urls whose copy the device cache keeps, or will when the load under way lands.
    private static var kept = Set<String>()
    private static func keeps(_ mode: String) -> Bool { Core.CacheMode(mode).keeps }
    private static var decoding: [String: [(UIImage?) -> Void]] = [:]
    private static let decoders = DispatchQueue(label: "lecodes.image-decode", qos: .userInitiated, attributes: .concurrent)

    /// The longer side of the screen, px: nothing is shown larger than it.
    private static let screenSide: Int = {
        let size = UIScreen.main.nativeBounds.size
        return max(Int(size.width), Int(size.height), 1)
    }()

    // MARK: the bytes

    /// nil token = answered in the call (from the cache, or a url that is none). The completion's
    /// nil = the url failed, or its bytes are no image. `cache` is the device cache's mode ("" = none).
    /// `shown`: is the asker's box on the screen now — asked while the request waits for a slot (see
    /// "Order" above); none = an asker nobody sees (a preload).
    @discardableResult
    public static func load(_ url: String, cache: String = "", shown: (() -> Bool)? = nil, _ completion: @escaping (Source?) -> Void) -> Token? {
        if let cached = sources.object(forKey: url as NSString) {
            if keeps(cache), kept.insert(url).inserted, cached.keepable { rendererServices?.keepCopy(url: url, data: cached.data) }
            completion(cached)
            return nil
        }
        let token = Token(url: url)
        if let running = requests[url] {
            if keeps(cache) {
                kept.insert(url)
                if !keeps(running.mode) { running.later = cache }
            }
            waiters[url, default: [:]][token.id] = completion
            if let shown { running.shown[token.id] = shown }
            token.request = running
            return token
        }
        guard URL(string: url) != nil, rendererServices != nil else { completion(nil); return nil }
        waiters[url, default: [:]][token.id] = completion
        let request = Request(url: url, mode: cache)
        if let shown { request.shown[token.id] = shown }
        if keeps(cache) { kept.insert(url) }
        requests[url] = request
        token.request = request
        if active < maxActive { start(request) } else { waiting.append(request) }
        return token
    }

    /// `request` goes to the host: a slot is taken.
    private static func start(_ request: Request) {
        active += 1
        request.started = true
        ask(request.url, request)
    }

    /// The request is over — answered, failed or cancelled, whichever is heard first: its slot is
    /// free. Then `refill`.
    private static func end(_ request: Request) {
        guard request.started, !request.ended else { return }
        request.ended = true
        active -= 1
    }

    /// The free slots go to the requests that wait: one shown now first, else the oldest.
    private static func refill() {
        while active < maxActive, !waiting.isEmpty {
            let index = waiting.firstIndex { request in request.shown.values.contains { $0() } } ?? 0
            start(waiting.remove(at: index))
        }
    }

    private static func ask(_ url: String, _ request: Request) {
        request.attempt += 1
        let attempt = request.attempt
        let mode = request.mode
        let landed: (Data?, Int) -> Void = { data, status in
            let source = data.flatMap { read(url: url, data: $0, keepable: status == 200) }
            DispatchQueue.main.async {
                // a cancelled request, heard of late: the slot is another request's now
                guard requests[url] === request, request.attempt == attempt else { return }
                if data == nil, let later = request.later {
                    // no answer, and an asker that joined reads the copy: once more, in its mode
                    request.later = nil
                    request.mode = later
                    ask(url, request)
                    return
                }
                if let source {
                    sources.setObject(source, forKey: url as NSString, cost: source.data.count)
                    // an asker that joined keeps the copy, and the mode of the request did not
                    if source.keepable, !keeps(mode), kept.contains(url) { rendererServices?.keepCopy(url: url, data: source.data) }
                }
                requests[url] = nil
                end(request)
                refill()
                let ws = waiters.removeValue(forKey: url) ?? [:]
                for w in ws.values { w(source) }
            }
        }
        request.handle = rendererServices.fetch(url: url, cache: mode, onSuccess: { data, status in landed(data, status) }, onError: { landed(nil, 0) })
    }

    private static func cancel(_ token: Token) {
        // a token outlives its request: only the request it waited on is touched
        guard let request = token.request, requests[token.url] === request, var ws = waiters[token.url] else { return }
        ws[token.id] = nil
        request.shown[token.id] = nil
        if ws.isEmpty {
            waiters[token.url] = nil
            requests[token.url] = nil
            request.handle?.cancel()
            end(request)
            waiting.removeAll { $0 === request }
            refill()
        } else {
            waiters[token.url] = ws
        }
    }

    /// The header of `data`: an image's stored size and its Exif turn. nil for what is no image.
    static func read(url: String, data: Data, keepable: Bool = false) -> Source? {
        guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        // 5…8 are the quarter turns: the picture is shown as wide as the stored frame is tall
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let turned = orientation >= 5 && orientation <= 8
        return Source(url: url, data: data, width: turned ? height : width, height: turned ? width : height, keepable: keepable)
    }

    // MARK: the pixels

    /// By how much `source` is halved for a box of `boxWidth` × `boxHeight` px (1, 2, 4, …): as far
    /// as the decoded picture still has a pixel for every pixel of the box, whichever way it is
    /// fitted — and, box or no box (0 = not known), until it is no larger than the screen.
    public static func sampleFor(_ source: Source, boxWidth: Int, boxHeight: Int) -> Int {
        var sample = 1
        while source.side / sample > screenSide { sample *= 2 }
        if boxWidth > 0, boxHeight > 0 {
            while source.width / (sample * 2) >= boxWidth, source.height / (sample * 2) >= boxHeight { sample *= 2 }
        }
        return sample
    }

    /// The pixels of `source`, halved by `sample`. The completion is called in this call when they
    /// are here already, later (on the main thread) otherwise; nil = the bytes do not decode.
    public static func decode(_ source: Source, sample: Int, _ completion: @escaping (UIImage?) -> Void) {
        let key = "\(source.url)#\(sample)"
        if let cached = images.object(forKey: key as NSString) { completion(cached); return }
        if decoding[key] != nil { decoding[key]?.append(completion); return }
        decoding[key] = [completion]
        decoders.async {
            let image = pixels(source, sample: sample)
            DispatchQueue.main.async {
                if let image, let cg = image.cgImage { images.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height) }
                let waiting = decoding.removeValue(forKey: key) ?? []
                for w in waiting { w(image) }
            }
        }
    }

    static func pixels(_ source: Source, sample: Int) -> UIImage? {
        guard let image = CGImageSourceCreateWithData(source.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let side = max(1, Int((Double(source.side) / Double(max(1, sample))).rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,   // decoded at this size — the full frame is never held
            kCGImageSourceCreateThumbnailWithTransform: true,     // the camera's Exif turn
            kCGImageSourceShouldCacheImmediately: true,           // decoded here, not at the first draw on the main thread
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary), cg.width > 0 else { return nil }
        // pixels per point such that `size` is the picture's own size (1 for a picture decoded whole)
        return UIImage(cgImage: cg, scale: CGFloat(cg.width) / CGFloat(source.width), orientation: .up)
    }

    // MARK: ahead of the view

    /// `url` brought into the caches ahead of the view that shows it (HostUI.preloadImage) — through
    /// `load` and `decode` themselves, so it joins a request or a decode already under way and a
    /// view asking meanwhile or later takes what it made. `boxWidth` × `boxHeight` px is the box the
    /// image will be shown in (0 = not known): with it the pixels are decoded as the view will want
    /// them (`sampleFor`) — it then shows them at its first layout; without it only the bytes are
    /// brought. The completion is called once — in this call when everything is here already —
    /// with false for an image that could not be loaded or decoded. `cache` is the device cache's
    /// mode: with one that keeps, the picture is there for a launch without a network.
    public static func preload(_ url: String, cache: String = "", boxWidth: Int, boxHeight: Int, _ completion: @escaping (Bool) -> Void) {
        load(url, cache: cache) { source in
            guard let source else { completion(false); return }
            guard boxWidth > 0, boxHeight > 0 else { completion(true); return }
            decode(source, sample: sampleFor(source, boxWidth: boxWidth, boxHeight: boxHeight)) { completion($0 != nil) }
        }
    }

    // MARK: both steps

    /// A url's image with no box of its own to decode for (a background): no larger than the screen.
    /// nil token = answered in the call. `shown`: as `load`'s.
    @discardableResult
    public static func image(_ url: String, shown: (() -> Bool)? = nil, _ completion: @escaping (UIImage?) -> Void) -> Token? {
        let token = Token(url: url)
        var answered = false
        token.inner = load(url, shown: shown) { source in
            guard !token.isCancelled else { return }
            guard let source else { answered = true; completion(nil); return }
            decode(source, sample: sampleFor(source, boxWidth: 0, boxHeight: 0)) { image in
                guard !token.isCancelled else { return }
                answered = true
                completion(image)
            }
        }
        return answered ? nil : token
    }
}
