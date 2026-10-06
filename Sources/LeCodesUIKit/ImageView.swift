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

    init(node: UINodeImage) {
        self.node = node
        super.init(frame: .zero)
        clipsToBounds = true
        contentMode = .scaleAspectFit
        isUserInteractionEnabled = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func setObjectFit(_ fit: CuiPaint.ObjectFit) {
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
        if svg != nil { setNeedsLayout() }
    }

    /// The SVG's bitmap for the current bounds and tint: the core's draw list aspect-fitted into the
    /// view's pixel box (letterboxed transparent), the painter's replay into a Surface context.
    private func renderSvgIfNeeded() {
        guard let svg else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if let r = svgRendered, r.size == size, r.tint == svgTint { return }
        let scale = UIScreen.main.scale
        let pw = Int((size.width * scale).rounded(.up)), ph = Int((size.height * scale).rounded(.up))
        guard let ctx = Surface.makeContext(width: pw, height: ph) else { return }
        let list = svg.draw(width: Float(pw), height: Float(ph), tint: svgTint)
        do {
            try CreatorCanvas.shared.painter.paint(ctx, DrawList(words: list.words, strings: list.strings))
        } catch {
            print("[ImageView] SVG draw list failed: \(error)")
            return
        }
        svgRendered = (size, svgTint)
        guard let cg = ctx.makeImage() else { return }
        image = UIImage(cgImage: cg, scale: scale, orientation: .up)
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
    /// What the view showed stays until then.
    func load(url: String) {
        loadToken?.cancel()
        loadToken = nil
        svg = nil
        svgRendered = nil
        // the answer below belongs to THIS request (the generation is taken after the bump)
        source = nil
        imageSample = 0
        decodingSample = 0
        sourceGeneration += 1
        let generation = sourceGeneration
        loadToken = ImageLoader.load(url) { [weak self] loaded in
            guard let self, self.sourceGeneration == generation, self.node?.isRemoved == false else { return }
            self.loadToken = nil
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
/// Main thread: every call and every answer; the bytes are fetched by URLSession and the pixels
/// decoded on a queue of this type.
public enum ImageLoader {
    /// An image as it came: its bytes, and its size AS IT IS SHOWN (a camera's quarter turn applied).
    public final class Source {
        public let url: String
        public let width: Int
        public let height: Int
        fileprivate let data: Data
        /// The longer side of the frame as it is stored.
        fileprivate let side: Int
        fileprivate init(url: String, data: Data, width: Int, height: Int) {
            self.url = url
            self.data = data
            self.width = width
            self.height = height
            self.side = max(width, height)
        }
    }

    public final class Token {
        fileprivate let url: String
        fileprivate let id = UUID()
        /// The request this token waits on (a later one for the same url is not its to cancel).
        fileprivate weak var task: URLSessionDataTask?
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
    private static var tasks: [String: URLSessionDataTask] = [:]
    private static var decoding: [String: [(UIImage?) -> Void]] = [:]
    private static let decoders = DispatchQueue(label: "lecodes.image-decode", qos: .userInitiated, attributes: .concurrent)

    /// The longer side of the screen, px: nothing is shown larger than it.
    private static let screenSide: Int = {
        let size = UIScreen.main.nativeBounds.size
        return max(Int(size.width), Int(size.height), 1)
    }()

    // MARK: the bytes

    /// nil token = answered in the call (from the cache, or a url that is none). The completion's
    /// nil = the url failed, or its bytes are no image.
    @discardableResult
    public static func load(_ url: String, _ completion: @escaping (Source?) -> Void) -> Token? {
        if let cached = sources.object(forKey: url as NSString) { completion(cached); return nil }
        let token = Token(url: url)
        if let running = tasks[url] {
            waiters[url, default: [:]][token.id] = completion
            token.task = running
            return token
        }
        guard let u = URL(string: url) else { completion(nil); return nil }
        waiters[url, default: [:]][token.id] = completion
        var task: URLSessionDataTask!
        task = URLSession.shared.dataTask(with: u) { data, _, _ in
            let source = data.flatMap { read(url: url, data: $0) }
            DispatchQueue.main.async {
                // a cancelled request, heard of late: the slot is another request's now
                guard tasks[url] === task else { return }
                if let source { sources.setObject(source, forKey: url as NSString, cost: source.data.count) }
                tasks[url] = nil
                let ws = waiters.removeValue(forKey: url) ?? [:]
                for w in ws.values { w(source) }
            }
        }
        task.priority = URLSessionTask.lowPriority
        tasks[url] = task
        token.task = task
        task.resume()
        return token
    }

    private static func cancel(_ token: Token) {
        // a token outlives its request: only the request it waited on is touched
        guard let task = token.task, tasks[token.url] === task, var ws = waiters[token.url] else { return }
        ws[token.id] = nil
        if ws.isEmpty {
            waiters[token.url] = nil
            tasks[token.url] = nil
            task.cancel()
        } else {
            waiters[token.url] = ws
        }
    }

    /// The header of `data`: an image's stored size and its Exif turn. nil for what is no image.
    static func read(url: String, data: Data) -> Source? {
        guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        // 5…8 are the quarter turns: the picture is shown as wide as the stored frame is tall
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let turned = orientation >= 5 && orientation <= 8
        return Source(url: url, data: data, width: turned ? height : width, height: turned ? width : height)
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

    // MARK: both steps

    /// A url's image with no box of its own to decode for (a background): no larger than the screen.
    /// nil token = answered in the call.
    @discardableResult
    public static func image(_ url: String, _ completion: @escaping (UIImage?) -> Void) -> Token? {
        let token = Token(url: url)
        var answered = false
        token.inner = load(url) { source in
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
