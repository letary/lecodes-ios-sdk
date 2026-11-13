// The node classes with a view of their own kind: the screen, the text, the button, the image. A
// container (column / row / box / scrollable-until-its-step / spacer) is UINodeContainer over a
// plain NodeView. Each class turns its part of the paint record into view state and answers the
// core's measure where it is a measured leaf.
import LeCodesCore
import UIKit

public final class UINodeScreen: UINodeContainer {
    override func createView() -> UIView { ScreenView(node: self) }

    /// Black over the screen, 0…1 — the pose of the screen under the other one in a transition.
    public private(set) var dim: CGFloat = 0

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        if r.dirty(CuiPaint.Bit.dim) {
            dim = CGFloat(r.float(CuiPaint.Word.dim))
            (view as? ScreenView)?.setDim(dim)
        }
        if r.dirty(CuiPaint.Bit.backgroundColor) { (UINode.appRoot as? UIRootHost)?.screenBackgroundChanged(self) }
    }
}

public final class UINodeButton: UINodeContainer {
    override func createView() -> UIView { ButtonView(node: self) }
    var isPressed: Bool { (view as? ButtonView)?.isPressedNow ?? false }
}

/// The text style a run reads from its record (rule 2: effective values, the core inherits): a text's
/// own — what its glyphs are set in —, and an image run's inherited one — its `1em`, its x-height,
/// the "…" a clamp draws when it hides the icon first (rules 10–12).
struct RunTextStyle {
    private(set) var fontSize: CGFloat = 14
    private var fontWeight = 400
    private var italic = false
    private var fontFamily = ""
    private(set) var font: UIFont = .systemFont(ofSize: 14)
    private(set) var color: UInt32?
    private(set) var decoration: CuiPaint.TextDecoration = .none

    /// The record's font, color and decoration fields that changed; true when the font moved
    /// (resolved again).
    mutating func read(_ r: PaintRecord) -> Bool {
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        let fontMoved = r.dirty(B.fontSize) || r.dirty(B.fontWeight) || r.dirty(B.fontStyle) || r.dirty(B.fontFamily)
        if r.dirty(B.color) { color = r.has(B.color) ? r.color(W.color) : nil }
        if r.dirty(B.fontSize) { fontSize = CGFloat(r.float(W.fontSize)) }
        if r.dirty(B.fontWeight) { fontWeight = Int(r.float(W.fontWeight)) }
        if r.dirty(B.fontStyle) { italic = r.word(W.fontStyle) == CuiPaint.FontStyle.italic.rawValue }
        if r.dirty(B.fontFamily) { fontFamily = r.has(B.fontFamily) ? r.string(W.fontFamily) : "" }
        if r.dirty(B.textDecoration) { decoration = CuiPaint.TextDecoration(rawValue: r.word(W.textDecoration)) ?? .none }
        if fontMoved { resolve() }
        return fontMoved
    }

    /// The decoration as a run draws it (TextRun).
    var runDecoration: TextRun.Decoration {
        decoration == .underline ? .underline : decoration == .line_through ? .lineThrough : .none
    }

    /// The face again (FontManager: one that was missing landed).
    mutating func resolve() {
        font = FontManager.font(family: fontFamily, weight: fontWeight, italic: italic, size: fontSize)
    }
}

/// A text: a block (a measured leaf with its own view, TextView / TextLabel) or an INLINE RUN of
/// another text (docs/plans/rich-text-plan.md) — the runtime's insertNode with a text as the parent.
/// A run is a record holder: no view, no box, no measure func (the core takes it away at the link).
/// Its record carries its effective text style (inherited from the paragraph through the core), its
/// `text` arrives like any text's, and every change of a run — its string, its record, a run in or
/// out, a face that landed — re-collects the PARAGRAPH's leaf runs into the paragraph's label
/// (`syncRuns`) and, when glyphs move, re-measures the paragraph. Runs nest; only leaves carry text
/// (rule 1). The style a run reads is the run style below; the paragraph props (lineHeight, align,
/// clamp, overflow, wrap) and the box are the paragraph's alone (rule 2). An IMAGE inside a text is a
/// run too (the appendix, rules 9–15): a leaf the label lays out as one placeholder character with
/// the image's box (UINodeImage.inlineSize) and draws the image's bitmap in.
public final class UINodeText: UINode {
    // The run style — every text's own: a block's label takes it, a paragraph reads its runs'.
    private var style = RunTextStyle()
    var fontSize: CGFloat { style.fontSize }
    var font: UIFont { style.font }
    private var color: UInt32? { style.color }
    private var decoration: CuiPaint.TextDecoration { style.decoration }
    private var letterSpacing: CGFloat = 0

    /// The runs in order — texts and images: a paragraph's, or a non-leaf run's.
    public private(set) var runs: [UINode] = []
    /// The outermost text up the run links: the one measured and drawn.
    var paragraph: UINodeText {
        var n = self
        while let o = n.inlineOwner { n = o }
        return n
    }
    /// The text's own string (a leaf's; a text with runs sends none).
    var text: String { content["text"] ?? "" }

    var label: TextLabel { (view as! TextView).label }

    public override init(id: Int, type: String) {
        super.init(id: id, type: type)
        TextNodes.add(self)
    }
    override func createView() -> UIView {
        let v = TextView(node: self)
        // What arrived while there was no view (a text is created before it is placed).
        v.label.content = text
        apply(collect(), to: v.label)
        return v
    }
    public override var hasMeasure: Bool { true }

    public override func setProperty(_ prop: String, _ value: String?) {
        super.setProperty(prop, value)
        guard prop == "text" else { return }
        if isRun { contentChanged(measure: true); return }
        if hasView { label.content = value ?? "" }
        FrameBatcher.request(self, measure: true)
    }

    public override func applyPaint(_ r: PaintRecord) {
        var r = r
        if needsFullPaint, !isRun {
            needsFullPaint = false
            r.allDirty = true
        }
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        let fontMoved = style.read(r)
        if r.dirty(B.letterSpacing) { letterSpacing = CGFloat(r.float(W.letterSpacing)) }
        if isRun {
            // No box: the highlight (backgroundColor), the opacity and the display are read for the
            // paragraph, which draws the run.
            readPaint(r)
            let relayout = fontMoved || r.dirty(B.letterSpacing)
            if relayout || r.anyDirty { contentChanged(measure: relayout) }
            return
        }
        super.applyPaint(r)
        let l = label
        if r.dirty(B.color) { l.textColor = color.map { UIColor(rgba: $0) } ?? .white }
        if r.dirty(B.lineHeight) { l.lineHeight = CGFloat(r.float(W.lineHeight)) }
        if r.dirty(B.letterSpacing) { l.letterSpacing = letterSpacing }
        if r.dirty(B.textAlign) {
            switch CuiPaint.TextAlign(rawValue: r.word(W.textAlign)) ?? .start {
            case .center: l.textAlignment = .center
            case .end, .right: l.textAlignment = .right
            case .start, .left: l.textAlignment = .left
            }
        }
        if r.dirty(B.textDecoration) {
            l.underline = decoration == .underline
            l.strikethrough = decoration == .line_through
        }
        if r.dirty(B.lineClamp) { l.lineClamp = max(0, Int(r.float(W.lineClamp))) }
        if r.dirty(B.textOverflow) { l.clipsOverflow = CuiPaint.TextOverflow(rawValue: r.word(W.textOverflow)) == .clip }
        if r.dirty(B.textWrap) { l.textWrap = CuiPaint.TextWrap(rawValue: r.word(W.textWrap)) ?? .wrap }
        if fontMoved { l.resolvedFont = font }
        if fontMoved || r.dirty(B.lineHeight) || r.dirty(B.letterSpacing) || r.dirty(B.lineClamp) || r.dirty(B.textOverflow) || r.dirty(B.textWrap) {
            FrameBatcher.request(self, measure: true)
        } else if r.anyDirty {
            label.setNeedsDisplay()
        }
    }

    /// A face landed (FontManager): re-resolve, re-measure.
    func fontChanged() {
        style.resolve()
        if isRun { contentChanged(measure: true); return }
        if hasView { label.resolvedFont = font }
        FrameBatcher.request(self, measure: true)
    }

    // MARK: - the runs

    /// The runtime's insertNode(this text, run, index): a text or an image.
    func insertRun(_ run: UINode, at index: Int) {
        guard run !== self, run is UINodeText || run is UINodeImage else { return }
        if let owner = run.inlineOwner, owner !== self { owner.removeRun(run) }
        runs.removeAll { $0 === run }
        runs.insert(run, at: min(max(index, 0), runs.count))
        run.inlineOwner = self
        if run.hasView { run.view.removeFromSuperview() }   // a view it had as a block never shows a run
        (run as? UINodeImage)?.becameRun()
        contentChanged(measure: true)
    }

    /// The runtime's removeNode(this text, run): a node of its own again, wherever it lands next.
    func removeRun(_ run: UINode) {
        guard let i = runs.firstIndex(where: { $0 === run }) else { return }
        runs.remove(at: i)
        run.inlineOwner = nil
        run.needsFullPaint = true
        (run as? UINodeImage)?.becameBlock()
        contentChanged(measure: true)
    }

    /// A run of this text was released (UINode.onRemoved): out of the line.
    func runReleased(_ run: UINode) {
        runs.removeAll { $0 === run }
        run.inlineOwner = nil
        contentChanged(measure: true)
    }

    /// Something this text's paragraph draws moved (a run's string, record or membership, an image
    /// run's bitmap): the paragraph re-collects its leaves; a change that moves glyphs re-measures it
    /// (the runtime dirtied its Yoga node for its own writes; a face that landed, a display flip or an
    /// image's size that arrived is the host's).
    func contentChanged(measure: Bool) {
        let p = paragraph
        guard !p.isRemoved else { return }
        p.syncRuns()
        if measure { FrameBatcher.request(p, measure: true) }
    }

    /// The leaf runs into the label — once there is one (a text with runs is still being built
    /// before it is placed; `createView` collects them then).
    private func syncRuns() {
        if hasView { apply(collect(), to: label) }
    }

    private func apply(_ c: Collected?, to label: TextLabel) {
        label.runs = c?.runs
        label.highlights = c?.highlights ?? []
        leafRanges = c?.ranges ?? [:]
        hasImageRun = c?.runs.contains { $0.image != nil } ?? false
    }
    /// The last collection held an image run: its box comes from its `width` / `height` STYLE, which
    /// no record carries — the runtime re-measures the paragraph on a change, and the measure
    /// re-collects.
    private var hasImageRun = false

    /// What the paragraph's label draws from its runs.
    struct Collected {
        var runs: [TextRun] = []
        var highlights: [TextHighlight] = []
        /// Each run's leaves (any depth, by node id): a range of `runs` — contiguous in pre-order.
        var ranges: [Int: Range<Int>] = [:]
    }
    /// The last collection's ranges (the paragraph's): a run's bounding rect reads them.
    private var leafRanges: [Int: Range<Int>] = [:]

    /// The leaf runs in pre-order, nil without runs (the plain string). Only leaves draw (rule 1); a
    /// non-leaf run gives its text style to its runs through the core and its opacity here; a run
    /// at any depth with a backgroundColor gets a highlight of its own (a box prop: never passed
    /// down), outer runs first. Every other box / layout prop of a run is ignored (`display` too).
    private func collect() -> Collected? {
        if runs.isEmpty { return nil }
        var out = Collected()
        collectLeaves(into: &out, alpha: 1)
        return out
    }

    private func collectLeaves(into out: inout Collected, alpha: CGFloat) {
        for run in runs where !run.isRemoved {
            let a = alpha * run.paint.opacity
            let start = out.runs.count
            if let image = run as? UINodeImage {
                // An image run (rules 9–12): one placeholder of the image's box, in the text style
                // the image inherited (its x-height places it; an ellipsis cutting at it is drawn in
                // it); no decoration, no highlight (an outer run's spans it).
                out.runs.append(TextRun(text: "\u{FFFC}", font: image.textStyle.font, letterSpacing: 0,
                                        color: Self.color(image.textStyle.color ?? 0xFFFFFFFF, alpha: a),
                                        decoration: image.textStyle.runDecoration, node: image.id, image: image.inlinePiece(opacity: a)))
                out.ranges[image.id] = start..<out.runs.count
                continue
            }
            guard let r = run as? UINodeText else { continue }
            var slot: Int?
            if let bg = r.paint.backgroundColor, bg & 0xFF != 0 {
                slot = out.highlights.count   // placed before the runs inside it: outer first
                out.highlights.append(TextHighlight(color: Self.color(bg, alpha: a), font: r.font, runs: start..<start))
            }
            if !r.runs.isEmpty {
                r.collectLeaves(into: &out, alpha: a)
            } else if !r.text.isEmpty {
                out.runs.append(TextRun(text: r.text, font: r.font, letterSpacing: r.letterSpacing,
                                        color: Self.color(r.color ?? 0xFFFFFFFF, alpha: a), decoration: r.style.runDecoration, node: r.id))
            }
            out.ranges[r.id] = start..<out.runs.count
            if let slot { out.highlights[slot].runs = start..<out.runs.count }
        }
    }

    static func color(_ rgba: UInt32, alpha: CGFloat) -> UIColor {
        let c = UIColor(rgba: rgba)
        return alpha >= 1 ? c : c.withAlphaComponent(CGFloat(rgba & 0xFF) / 255 * max(0, alpha))
    }

    private func applyPendingRuns() {
        for r in runs where !r.isRemoved {
            PaintBatch.applyPending(r)
            (r as? UINodeText)?.applyPendingRuns()
        }
    }

    // MARK: - touches (rule 5)

    /// A press target (the button rule: the press and touchStart go to an INTERACTIVE node, the click
    /// only where CLICK is set too — PressTracker; the SDK's onClick sets both bits).
    var takesPress: Bool { has(TreeEvents.TREE_FLAG_INTERACTIVE) }

    /// What a finger at `point` (the label's space) presses: the innermost INTERACTIVE run under it
    /// (a text's glyphs, an image's box — rule 13), else an outer one, else this paragraph when it is
    /// interactive, else nil — the touch is not the text's and goes on as a plain label's always did.
    func touchTarget(at point: CGPoint) -> UINode? {
        if !runs.isEmpty, let leaf = label.runIndex(at: point), let leaves = label.runs, leaf < leaves.count {
            var n = Nodes[leaves[leaf].node]
            while let cur = n, cur !== self {
                if cur.has(TreeEvents.TREE_FLAG_INTERACTIVE), !cur.isRemoved { return cur }
                n = cur.inlineOwner
            }
        }
        return takesPress ? self : nil
    }

    /// The rect of run `id` of this paragraph (HostUI.getBoundingRect of a run): the bounding box of
    /// its fragments on the lines, in the app root's space; a run the clamp dropped is a zero rect at
    /// the content origin.
    func runBoundingRect(_ id: Int) -> [Float]? {
        guard hasView, lastLayout != nil, let root = UINode.appRoot, view.isDescendant(of: root),
              let range = leafRanges[id] else { return nil }
        let r = label.convert(label.fragmentsRect(of: range), to: root)
        return [Float(r.origin.x), Float(r.origin.y), Float(r.width), Float(r.height)]
    }

    // MARK: - the box

    override func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        if needsFullPaint, let ptr = CreatorUI.paintOf(id) { applyPaint(PaintRecord(base: ptr)) }
        applyPendingRuns()   // a measure ahead of the frame's paint sync reads the runs' records too
        if hasImageRun { syncRuns() }   // an image run's width / height moved (no record says so)
        return label.measure(width: width, widthMode: widthMode, height: height, heightMode: heightMode)
    }

    /// Placed in a container as a block after being a run: its box and label take the whole record.
    override func attached(to parent: UINodeContainer?) {
        super.attached(to: parent)
        if parent != nil, needsFullPaint, let ptr = CreatorUI.paintOf(id) { applyPaint(PaintRecord(base: ptr)) }
    }

    /// The padding is the core's: the label draws inside it.
    override func frameApplied() {
        let p = CreatorUI.padding(id)
        label.inset = UIEdgeInsets(top: CGFloat(p.top), left: CGFloat(p.left), bottom: CGFloat(p.bottom), right: CGFloat(p.right))
    }

    public override func onRemoved() {
        super.onRemoved()   // released as a run: out of its paragraph's line
        TextNodes.remove(self)
        runs.removeAll()
    }
}

/// An image: a block (a measured leaf with its own view, ImageView) or an IMAGE RUN of a text — an
/// icon in a line (docs/plans/rich-text-plan.md, the appendix: rules 9–15). A run has no view in the
/// hierarchy and no box: its paragraph's label lays it out as one placeholder (`inlinePiece`) and
/// draws `inline`'s bitmap there as the image would draw itself — its objectFit, an atlas crop, its
/// tint, its corner radii, its own backgroundColor under it, its opacity. The source arrives before
/// the link (the SDK writes it when it makes the node), so the view it made then hands it over at the
/// link (`becameRun`) and takes it back at an unlink (`becameBlock`).
///
/// TREE_EVENT_IMAGE (tree-events.h; the SDK's onLoad / onError): what is known of the picture of the
/// current `src` is kept here (`imageOutcome`) and told ONCE per src to a node that listens —
/// `imageSettled`, called by whatever resolved the source (the view, a run's InlineImage).
///
/// The preview (the "preview" prop): a second picture drawn in the box while the node's own is not
/// there (`previewBitmap`) — by the view for a block (ImageView.syncPreview), by the paragraph for a
/// run (`inlinePiece`).
public final class UINodeImage: UINode {
    private var imageView: ImageView { view as! ImageView }
    /// The one tint (the source's own through the core's cascade): applies to SVG only.
    private(set) var tintColor: UInt32?
    /// The bitmap of the image as a run; nil for a block.
    private(set) var inline: InlineImage?
    /// As a run: the text style it inherited (its 1em, its x-height, an ellipsis cutting at it) and
    /// its objectFit (the record's, cover unless set).
    private(set) var textStyle = RunTextStyle()
    private var objectFit: CuiPaint.ObjectFit = .cover

    override func createView() -> UIView { ImageView(node: self) }
    public override var hasMeasure: Bool { true }

    public override func setProperty(_ prop: String, _ value: String?) {
        let cacheMoved = prop == "cache" && (value ?? "") != cacheMode
        super.setProperty(prop, value)
        if prop == "src" {
            // A new src: its own TREE_EVENT_IMAGE (before the source is resolved below — a picture in
            // memory settles in that call). A `cache` change asks for the same picture again and is
            // told nothing new.
            imageOutcome = nil
            imageReported = false
            srcEpoch += 1
        }
        if prop == "preview" || cacheMoved {
            // The preview is loaded in the node's cache mode, when the box next needs it (previewBitmap).
            dropPreview()
            previewChanged()
        }
        if let inline {
            // A run draws its source in its box (an atlas crop: its aspect and what fills the box).
            if prop == "src" || cacheMoved { inline.setSource(content["src"] ?? "", cache: cacheMode) }
            if prop == "src" || prop == "sourceRect" { inlineOwner?.contentChanged(measure: true) }   // the aspect may size the box (rule 10)
            return
        }
        switch prop {
        case "src": setSource(value ?? "")
        case "sourceRect": setSourceRect(value)
        case "cache": if cacheMoved, ImageSourceKind.isUrl(content["src"] ?? "") { setSource(content["src"] ?? "") }
        default: break
        }
    }

    /// The device cache's mode of a URL source (`UIImage(url).cache(mode)`, docs/cache.md; "" =
    /// none). The SDK writes it AFTER the `src` of the same commit, when the url's load is already
    /// under way in no mode — so a change of it asks for the url again in the new mode. The loader
    /// joins the load under way and owes this asker what its mode promises (ImageLoader, "the device
    /// cache"): no second request is made unless the first one brings nothing.
    private var cacheMode: String { content["cache"] ?? "" }

    private func setSourceRect(_ value: String?) {
        let parts = (value ?? "").split(separator: " ").compactMap { Double($0) }
        imageView.sourceRect = parts.count == 4 ? CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) : nil
        imageView.applySourceRectCrop()
        FrameBatcher.request(self, measure: true)
    }

    private func setSource(_ src: String) {
        let v = imageView
        let kind = ImageSourceKind.of(src)
        if case .canvas(let id) = kind {
            // A baked _creatorCanvas surface (UIImage(canvas)): the painter host's pixels, bound so a
            // later Canvas.update() repaints this node in place.
            if let id { v.setCanvas(id) } else { v.unbindCanvas(); v.setImage(nil) }
            return
        }
        v.unbindCanvas()   // every other source drops the binding
        if case .scene2d(let id) = kind {
            // A LIVE 2D scene as the source: the engine draws it under the view every frame.
            if let id { v.setScene2d(id) } else { v.unbindScene2d(); v.setImage(nil) }
            return
        }
        v.unbindScene2d()
        switch kind {
        case .svg(let markup):
            v.setSvg(markup)
            // its document's size (parsed once per markup: the document the view just took)
            imageSettled(SvgDocuments.get(markup).map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) })
        case .raster(let image):
            v.setImage(image)
            imageSettled(image.map { CGSize(width: $0.size.width * $0.scale, height: $0.size.height * $0.scale) })
        case .url(let url): v.load(url: url, cache: cacheMode)   // settles when the url answers (ImageView.load)
        case .none, .canvas, .scene2d: v.setImage(nil)
        }
    }

    // MARK: - TREE_EVENT_IMAGE

    /// What is known of the picture of the current `src`: it is there (its own pixel size — a URL's
    /// as its header says, before its pixels are decoded down to the box; an SVG's document size),
    /// or it will not be (the url failed, the bytes are no picture). nil = not known yet (a url on
    /// its way), or nothing to load: an empty src, a canvas surface, a live scene — never reported.
    private var imageOutcome: (ok: Bool, width: Int32, height: Int32)?
    /// The event went for this src; cleared by a src write and by the node gaining TREE_FLAG_IMAGE.
    private var imageReported = false
    /// Counts the src writes: an event posted for a src the node has left since is not delivered.
    private var srcEpoch = 0
    private var listensImage = false

    /// The source was resolved: `size` = the picture's own pixels, nil = it will not be there.
    func imageSettled(_ size: CGSize?) {
        imageOutcome = size.map { (true, Int32($0.width.rounded()), Int32($0.height.rounded())) } ?? (false, 0, 0)
        reportImage()
    }

    /// Once per src, only to a node that listens; posted — the outcome is often learned inside the
    /// runtime's own write of the src (a picture in memory).
    private func reportImage() {
        guard !imageReported, !isRemoved, has(TreeEvents.TREE_FLAG_IMAGE), let outcome = imageOutcome else { return }
        imageReported = true
        let id = id, epoch = srcEpoch
        JSThread.post { [weak self] in
            guard let self, !self.isRemoved, self.srcEpoch == epoch else { return }
            Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_IMAGE, [.int(outcome.ok ? 1 : 0), .int(outcome.width), .int(outcome.height)])
        }
    }

    /// A listener that came after the picture (TREE_FLAG_IMAGE gained): the node is told again.
    public override func flagsChanged() {
        let listens = has(TreeEvents.TREE_FLAG_IMAGE)
        if listens, !listensImage {
            imageReported = false
            reportImage()
        }
        listensImage = listens
    }

    // MARK: - the preview

    var hasPreview: Bool { !(content["preview"] ?? "").isEmpty }
    /// The preview's loader, made when a box first needs it and dropped when the picture is there:
    /// the same loader and caches as a src (InlineImage), in the node's cache mode; it has no
    /// `settled` — a preview reports nothing, and one that fails is no preview.
    private var previewImage: InlineImage?

    /// The preview for a box of `box` points: its pixels and where the whole picture lands in the box
    /// by `fit` alone (a `sourceRect` is a crop of the src's own pixels), the node's tint on an svg.
    /// nil = no preview, or not here yet (`previewChanged` tells when it is).
    func previewBitmap(in box: CGSize, fit: CuiPaint.ObjectFit) -> (bitmap: UIImage, place: CGRect)? {
        guard hasPreview, box.width > 0, box.height > 0 else { return nil }
        let loader: InlineImage
        if let previewImage { loader = previewImage } else {
            loader = InlineImage(shown: { [weak self] in
                guard let self else { return false }
                if let paragraph = self.inlineOwner?.paragraph { return paragraph.hasView && paragraph.view.isShownOnScreen }
                return self.hasView && self.view.isShownOnScreen
            }) { [weak self] _ in self?.previewChanged() }
            previewImage = loader
            loader.setSource(content["preview"] ?? "", cache: cacheMode)
        }
        guard let natural = loader.naturalSize, natural.width > 0, natural.height > 0 else { return nil }
        let place = InlineImage.place(natural, crop: nil, fit: fit, in: box)
        guard let bitmap = loader.bitmap(for: place.size, tint: tintColor) else { return nil }
        return (bitmap, place)
    }

    func dropPreview() {
        previewImage?.cancel()
        previewImage = nil
    }

    /// The preview was set, or its picture landed: a redraw of the box — never a measure.
    private func previewChanged() {
        if isRun { inlineOwner?.contentChanged(measure: false) } else if hasView { imageView.setNeedsLayout() }
    }

    /// Canvas.update() on the surface this node shows (CanvasSurfaces).
    func refreshCanvasSurface(_ surfaceId: Int32) { if inline == nil { imageView.refreshCanvasSurface(surfaceId) } }

    public override func applyPaint(_ r: PaintRecord) {
        var r = r
        if needsFullPaint, !isRun {
            needsFullPaint = false
            r.allDirty = true
        }
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        if r.dirty(B.tintColor) { tintColor = r.has(B.tintColor) ? r.color(W.tintColor) : nil }
        if isRun {
            // No box: the paragraph draws the icon from these — the box fields (opacity, corner
            // radii, backgroundColor), the fit, the inherited text style (its em and x-height size
            // and place it: a re-measure).
            readPaint(r)
            if r.dirty(B.objectFit) { objectFit = CuiPaint.ObjectFit(rawValue: r.word(W.objectFit)) ?? .cover }
            let fontMoved = textStyle.read(r)
            if fontMoved || r.anyDirty { inlineOwner?.contentChanged(measure: fontMoved) }
            return
        }
        super.applyPaint(r)
        if r.dirty(B.objectFit) { imageView.setObjectFit(CuiPaint.ObjectFit(rawValue: r.word(W.objectFit)) ?? .contain) }
        if r.dirty(B.tintColor) { imageView.setTint(tintColor) }
    }

    override func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        if needsFullPaint, let ptr = CreatorUI.paintOf(id) { applyPaint(PaintRecord(base: ptr)) }
        return imageView.measure(width: width, widthMode: widthMode, height: height, heightMode: heightMode)
    }

    /// Placed in a container as a block after being a run: its box and view take the whole record.
    override func attached(to parent: UINodeContainer?) {
        super.attached(to: parent)
        if parent != nil, needsFullPaint, let ptr = CreatorUI.paintOf(id) { applyPaint(PaintRecord(base: ptr)) }
    }

    // MARK: - an image run (rules 9–13)

    /// Linked into a text (UINodeText.insertRun): the bitmap loads here — first, so a URL the view
    /// is still fetching is joined, not fetched again — and the view gives its source up.
    func becameRun() {
        guard inline == nil else { return }
        let image = InlineImage(shown: { [weak self] in
            guard let paragraph = self?.inlineOwner?.paragraph, paragraph.hasView else { return false }
            return paragraph.view.isShownOnScreen
        }) { [weak self] sizeMoved in self?.inlineOwner?.contentChanged(measure: sizeMoved) }
        image.settled = { [weak self] in self?.imageSettled($0) }
        inline = image
        image.setSource(content["src"] ?? "", cache: cacheMode)
        TextNodes.add(self)   // its x-height is a face's
        // What it took as a block is not what it draws with: the whole current record (the core
        // gave it the text style it inherits at the link).
        if let ptr = CreatorUI.paintOf(id) {
            var r = PaintRecord(base: ptr)
            r.allDirty = true
            applyPaint(r)
        }
        guard hasView else { return }
        let v = imageView
        v.unbindCanvas()
        v.unbindScene2d()
        v.setImage(nil, remeasure: false)   // cancels a load, drops an svg and the pixels
    }

    /// Unlinked (UINodeText.removeRun): a block again — the view takes the source (and a crop) back.
    func becameBlock() {
        guard let image = inline else { return }
        image.cancel()
        inline = nil
        TextNodes.remove(self)
        if let src = content["src"] { setSource(src) }
        if let rect = content["sourceRect"] { setSourceRect(rect) }
    }

    /// A face landed (FontManager): an image run's x-height may have moved.
    func fontChanged() {
        guard isRun else { return }
        textStyle.resolve()
        inlineOwner?.contentChanged(measure: true)
    }

    /// The atlas crop (`sourceRect`, texture px), nil without one.
    private var crop: CGRect? {
        let parts = (content["sourceRect"] ?? "").split(separator: " ").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// The box of the image as a run, points, not rounded (rule 10): both `width` / `height` styles
    /// are that box; one sets the other from the aspect of the atlas crop, else of the source (1:1
    /// until it is known); none is a square of the font size it inherited (`1em`, CSS's: the
    /// enclosing run's). A percent or `auto` is not set (CreatorUI.sizeStyle).
    func inlineSize() -> CGSize {
        let style = CreatorUI.sizeStyle(id)
        let shape = crop?.size ?? inline?.naturalSize ?? .zero
        let aspect = shape.width > 0 && shape.height > 0 ? shape.width / shape.height : 1
        switch (style.width.map { CGFloat($0) }, style.height.map { CGFloat($0) }) {
        case let (w?, h?): return CGSize(width: w, height: h)
        case let (w?, nil): return CGSize(width: w, height: w / aspect)
        case let (nil, h?): return CGSize(width: h * aspect, height: h)
        case (nil, nil): return CGSize(width: textStyle.fontSize, height: textStyle.fontSize)
        }
    }

    /// The image as its paragraph lays it out and draws it (rule 12): the box, where the whole
    /// picture lands in it (an atlas crop fills the box, else the objectFit), the pixels for that
    /// (nil until they arrive), the corner radii, the own backgroundColor, `opacity` (its own × the
    /// run chain's).
    func inlinePiece(opacity: CGFloat) -> ImagePiece {
        let box = inlineSize()
        var content: CGRect?
        var bitmap: UIImage?
        if let inline, let natural = inline.naturalSize, natural.width > 0, natural.height > 0, box.width > 0, box.height > 0 {
            let place = InlineImage.place(natural, crop: crop, fit: objectFit, in: box)
            content = place
            bitmap = inline.bitmap(for: place.size, tint: tintColor)
        }
        // The picture is not there to draw (on its way, or it failed): its preview stands in the box,
        // by the objectFit alone. The box itself is the src's (inlineSize): a preview sizes nothing.
        if bitmap != nil { dropPreview() }
        else if let standIn = previewBitmap(in: box, fit: objectFit) {
            content = standIn.place
            bitmap = standIn.bitmap
        }
        let bg = paint.backgroundColor.flatMap { $0 & 0xFF != 0 ? UIColor(rgba: $0) : nil }
        return ImagePiece(size: box, content: content, bitmap: bitmap, background: bg, opacity: opacity, radius: paint.radius)
    }

    public override func onRemoved() {
        super.onRemoved()   // released as a run: out of its paragraph's line
        TextNodes.remove(self)
        inline?.cancel()
        dropPreview()
        guard hasView else { return }
        imageView.cancelLoad()
        imageView.unbindCanvas()
        imageView.unbindScene2d()
    }
}

/// A widget root: a screen-like root shown over (or inside) its owner, with an optional scrim
/// behind it (`overlayColor`: a sibling view directly behind the widget, tapped → OVERLAY_TAP)
/// and, for a bottom sheet (`sheetDetents`), the sheet behavior. The behavior lives on the NODE:
/// styles arrive before the widget is mounted. Style order is not guaranteed — `sheetDetent` /
/// `sheetDismissible` may arrive before `sheetDetents` creates the behavior; parked and consumed.
public final class UINodeWidget: UINodeContainer {
    public private(set) var overlayColor: UInt32?
    public private(set) var overlay: WidgetOverlayView?
    public private(set) var sheet: WidgetSheetBehavior?
    private var pendingSheetDetent = 0
    private var pendingSheetDismissible = true

    override func createView() -> UIView { WidgetView(node: self) }

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        if r.dirty(B.overlayColor) {
            overlayColor = r.has(B.overlayColor) ? r.color(W.overlayColor) : nil
            if overlayColor == nil { removeOverlay() } else { applyOverlay() }
        }
        if r.dirty(B.sheetDetents) { setSheetDetents(r.string(W.sheetDetents)) }
        if r.dirty(B.sheetDetent) { setSheetDetent(Int(r.float(W.sheetDetent))) }
        if r.dirty(B.sheetDismissible) { setSheetDismissible(r.bool(W.sheetDismissible)) }
    }

    // MARK: - the scrim

    /// Create / recolor the scrim once the widget's view has a parent: directly behind it.
    public func applyOverlay() {
        guard let color = overlayColor, let parent = view.superview else { return }
        if let o = overlay, o.superview !== parent { o.removeFromSuperview(); overlay = nil }
        let o = overlay ?? {
            let v = WidgetOverlayView(widget: self)
            overlay = v
            return v
        }()
        o.backgroundColor = UIColor(rgba: color)
        o.place(parent.bounds)
        o.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Directly behind the widget EVERY time, not only when the scrim is new: a show() moves the
        // widget to the tail of its root's children (plan decision 8 — remove + insert, the view
        // re-added above its new previous sibling), and a scrim left at the old index would sit
        // under the widgets declared after it, which then paint over it undimmed.
        parent.insertSubview(o, belowSubview: view)
        followShadow(reorder: true)   // the scrim went in between: the shadow back over it
    }

    public func removeOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// Above the parent's content, the scrim directly behind, whatever order the views were added.
    public func bringToFront() {
        guard let parent = view.superview else { return }
        if let overlay, overlay.superview === parent { parent.bringSubviewToFront(overlay) }
        parent.bringSubviewToFront(view)
        followShadow(reorder: true)
    }

    // MARK: - the sheet

    private func setSheetDetents(_ value: String) {
        let list = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }.map { CGFloat($0) }.sorted()
        guard !list.isEmpty else { return }
        if let sheet { sheet.detents = list; return }
        let behavior = WidgetSheetBehavior(widget: self)
        behavior.detents = list
        behavior.dismissible = pendingSheetDismissible
        sheet = behavior
        behavior.setDetent(pendingSheetDetent, animated: false)
        if lastLayout != nil { behavior.layoutDidApply() }   // already laid out (the style arrived after the show)
    }
    private func setSheetDetent(_ index: Int) {
        if let sheet { sheet.setDetent(index, animated: true) } else { pendingSheetDetent = index }
    }
    private func setSheetDismissible(_ value: Bool) {
        if let sheet { sheet.dismissible = value } else { pendingSheetDismissible = value }
    }

    /// The walk visited the widget: the sheet re-composes its offset; the first valid layout plays
    /// the entrance. Outside the walk's dedupe on purpose (a pass reporting "unchanged" still owes it).
    override func layoutVisited() {
        sheet?.layoutDidApply()
    }

    /// Unmounted from its root (the runtime's removeNode: hidden by its display once the exit
    /// landed, its page left, its screen covered): the scrim is no node's view, so the container's
    /// remove does not take it — without this it stayed in the root's view, dimming the screen and
    /// swallowing every touch after the dialog closed. The view itself persists (the node owns it)
    /// and is re-added at the next mount, so a sheet owes its entrance again then and nothing of
    /// its exit offset carries over (Android's `unmounted`, whose view is dropped with the node) —
    /// decided at the frame (FrameBatcher.widgetDetached): a widget removed and inserted again in
    /// one commit is MOVED (the runtime re-inserts a root's widgets in their new order — a show()
    /// brings one to the front), and its sheet stays where it stands, nothing entering again. The
    /// scrim is made again behind it by the insert (HostUIRenderer.insertNode → applyOverlay).
    override func attached(to parent: UINodeContainer?) {
        super.attached(to: parent)
        if parent == nil {
            removeOverlay()
            if sheet != nil { FrameBatcher.widgetDetached(self) }
        }
    }

    /// The frame after a removal (FrameBatcher): still out of every root — not moved — the sheet
    /// owes its entrance at the next mount.
    func settleDetached() {
        if parent == nil, !isRemoved { sheet?.unmounted() }
    }

    public override func onRemoved() {
        super.onRemoved()
        removeOverlay()
    }
}

/// A scrollable container ("scrollable", "scrollableScreen"): the scroll-side of the paint record
/// onto its ScrollContainerView, the scroll events gated on the flags, the content size after
/// every layout visit.
public class UINodeScrollable: UINodeContainer {
    var scrollView: ScrollContainerView { view as! ScrollContainerView }
    override func createView() -> UIView { ScrollContainerView(node: self) }

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        let v = scrollView
        if r.dirty(B.scrollDirection) {
            switch CuiPaint.ScrollDirection(rawValue: r.word(W.scrollDirection)) ?? .vertical {
            case .vertical: v.axis = .vertical
            case .horizontal: v.axis = .horizontal
            case .all: v.axis = .both
            }
        }
        if r.dirty(B.overscrollMode) {
            switch CuiPaint.OverscrollMode(rawValue: r.word(W.overscrollMode)) {
            case .none?: v.overscrollMode = .none
            case .absorb?: v.overscrollMode = .absorb
            default: v.overscrollMode = .bounce
            }
        }
        if r.dirty(B.snap) {
            switch CuiPaint.Snap(rawValue: r.word(W.snap)) {
            case .start?: v.snapAlign = .start
            case .center?: v.snapAlign = .center
            case .end?: v.snapAlign = .end
            default: v.snapAlign = .none
            }
        }
        if r.dirty(B.showScrollbar) {
            let show = r.bool(W.showScrollbar)
            v.showsVerticalScrollIndicator = show
            v.showsHorizontalScrollIndicator = show
        }
        if r.dirty(B.keyboardDismissMode) {
            switch CuiPaint.KeyboardDismissMode(rawValue: r.word(W.keyboardDismissMode)) {
            case .scroll?: v.keyboardDismissMode = .onDrag
            case .none?: v.keyboardDismissMode = .none
            default: v.keyboardDismissMode = .interactive
            }
        }
        if r.dirty(B.refreshControlColor) { v.refreshTint = r.has(B.refreshControlColor) ? UIColor(rgba: r.color(W.refreshControlColor)) : nil }
    }

    public override func flagsChanged() {
        scrollView.setRefreshEnabled(has(TreeEvents.TREE_FLAG_REFRESH))
    }

    override func layoutFinished() {
        scrollView.updateContentSize()
    }

    // MARK: - the host's keyboard (KeyboardLayoutController)

    /// The scroll view itself (its offset, insets and content size, read by the host).
    public var scroll: UIScrollView { scrollView }
    public var isVertical: Bool { scrollView.axis == .vertical }
    /// Native inset mode: the keyboard's band as this view's bottom contentInset — the frame stays
    /// under the keyboard, no relayout; a clear that lands mid-gesture waits for the settle.
    public func setKeyboardInset(_ inset: CGFloat) { scrollView.setKeyboardInset(inset) }
    public func clearKeyboardInset() { scrollView.clearKeyboardInset() }
    public var keyboardInset: CGFloat { scrollView.contentInset.bottom }
    /// Scroll so `view` (a descendant) is visible above the keyboard band, `margin` pt of room.
    public func reveal(_ view: UIView, margin: CGFloat = 24) {
        guard view.isDescendant(of: scrollView) else { return }
        scrollView.reveal(view.convert(view.bounds, to: scrollView), margin: margin)
    }

    // The scroll events by id, gated on the flag mask. `max` = the content beyond the viewport.
    func onScroll(_ offset: CGFloat, max: CGFloat) {
        if has(TreeEvents.TREE_FLAG_SCROLL) { Core.nodeScroll(id, scrollTop: Float(offset), maxScroll: Float(max)) }
    }
    func onOverscroll(_ value: CGFloat) {
        if has(TreeEvents.TREE_FLAG_OVERSCROLL) { Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_OVERSCROLL, [.double(Double(value))]) }
    }
    func onScrollRelease() {
        if has(TreeEvents.TREE_FLAG_SCROLL_RELEASE) { Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_SCROLL_RELEASE) }
    }
}

/// The virtualized list: the core's window over a VListView. Its children are the mounted items
/// (the runtime's insertNode / removeNode with this node as the parent), detached yoga roots the
/// core places by offset; every layout visit drives vlistUpdateLayout FIRST (it may mount /
/// unmount and refresh the height cache), then the content height, then the items, then a
/// pending anchored scroll.
public final class UINodeVList: UINodeScrollable {
    private var list: VListView { view as! VListView }
    override func createView() -> UIView { VListView(node: self) }

    override func layoutVisited() {
        CreatorUI.vlistUpdateLayout(id)
    }
    override func layoutFinished() {
        list.updateContentSize()
        list.placeItems()
        list.applyPendingScroll()
    }

    /// A row's box: the core's offset of its item root, then the row's own box inside that root —
    /// its margins, its alignSelf (NaN = not mounted yet: keep the y).
    func placeRow(_ row: UINode, box r: CGRect) {
        let top = CGFloat(CreatorUI.vlistItemOffset(id, itemRoot: row.id))
        let y = top.isFinite ? top + r.minY : row.view.placement.minY
        row.box.applyFrame(CGRect(x: r.minX, y: y, width: r.width, height: r.height))
    }

    /// HostUI.vlistScroll.
    func applyScroll(_ y: CGFloat, animated: Bool) {
        if animated {
            list.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        } else {
            list.pendingScrollY = y
            FrameBatcher.request(self)
        }
    }
}

/// The pager: its children are its PAGES (screen roots the runtime attaches through insertNode,
/// tab-major), placed by PagerView in tab cells; the runtime owns the tabs, the stacks and the
/// page lifecycle, this node only routes.
public final class UINodePager: UINodeContainer {
    /// The node's view is the mount — the box, and the system's back swipe over the pager
    /// inside it (PagerMount); the pages sit in the pager's own view.
    var pagerView: PagerView { (view as! PagerMount).pager }
    override func createView() -> UIView { PagerMount(node: self) }

    /// The page the pager shows now: the top of the selected tab, straight from the runtime.
    public var currentPage: UINode? {
        let tabs = Core.pagerTabCount(id)
        guard tabs > 0 else { return nil }
        let tab = min(max(Core.pagerSelectedIndex(id), 0), tabs - 1)
        let len = Core.pagerStackLen(id, tab: tab)
        guard len > 0 else { return nil }
        return Nodes[Core.pagerPageNode(id, tab: tab, pos: len - 1)]
    }

    /// Is `node` a page of a live pager (its view sits in the pager's view)? The owner a widget
    /// attached to a page mounts into — for EVERY tab, not just the one on screen.
    public static func isLivePage(_ node: UINode) -> Bool {
        guard let pager = node.parent as? UINodePager, !pager.isRemoved, !node.isRemoved else { return false }
        return pager.pagerView.holds(node)
    }
    /// Is `node` the page its pager shows?
    public static func isCurrentPage(_ node: UINode) -> Bool {
        guard let pager = node.parent as? UINodePager, !pager.isRemoved else { return false }
        return pager.currentPage === node
    }

    /// The pager's view takes its size from the mount through UIKit's own layout: made now, the
    /// pages are placed against the box this pass gave.
    override func layoutVisited() {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        pagerView.layoutPages()
    }

    /// A page's view goes under the pager's view, in the children's order.
    override func childInserted(_ child: UINode) {
        let i = children.firstIndex { $0 === child } ?? 0
        let pager = pagerView
        if i > 0, children[i - 1].view.superview === pager { pager.insertSubview(child.view, aboveSubview: children[i - 1].view) }
        else { pager.insertSubview(child.view, at: 0) }
        child.followShadow(reorder: true)
        FrameBatcher.request(self)
    }

    /// A released page's view goes — unless the pager's view is still sliding it away.
    override func childRemoved(_ child: UINode) {
        if pagerView.releases(child) { super.childRemoved(child) } else { FrameBatcher.request(self) }
    }
}

/// An input ("input": one line, "textarea": auto-growing): the value and the focus over the
/// content channel, the traits from the paint record, the events by id gated on the flags,
/// posted; the keyboard policies the keyboard step reads.
public final class UINodeInput: UINode {
    public let multiline: Bool
    private var control: InputControl { view as! InputControl }
    private(set) var fontSize: CGFloat = 14
    private var fontWeight = 400
    private var italic = false
    private var fontFamily = ""
    private var placeholderText: String?
    private var placeholderColor: UIColor?
    /// The keyboard policies (keyboardShrink / keyboardDismiss): who is focused decides.
    public private(set) var keyboardShrink = true
    public private(set) var keyboardDismiss = true
    public private(set) var isFocused = false

    public override init(id: Int, type: String) {
        multiline = type == "textarea"
        super.init(id: id, type: type)
        TextNodes.add(self)
    }
    override func createView() -> UIView { multiline ? TextAreaView(node: self) : InputFieldView(node: self) }
    public override var hasMeasure: Bool { true }

    /// The live text (HostUI.getTextValue): canonical for the picker kinds.
    public var textValue: String { control.textValue }

    public override func setProperty(_ prop: String, _ value: String?) {
        super.setProperty(prop, value)
        switch prop {
        case "value": control.setValue(value ?? "")
        case "focus": control.setFocused(value == "1")
        case "placeholder": placeholderText = value; control.applyPlaceholder(placeholderText, color: placeholderColor)
        default: break
        }
    }

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        let c = control
        var fontChanged = false
        if r.dirty(B.color) { c.applyTextColor(r.has(B.color) ? UIColor(rgba: r.color(W.color)) : InputDefaults.textColor) }
        if r.dirty(B.fontSize) { fontSize = CGFloat(r.float(W.fontSize)); fontChanged = true }
        if r.dirty(B.fontWeight) { fontWeight = Int(r.float(W.fontWeight)); fontChanged = true }
        if r.dirty(B.fontStyle) { italic = r.word(W.fontStyle) == CuiPaint.FontStyle.italic.rawValue; fontChanged = true }
        if r.dirty(B.fontFamily) { fontFamily = r.has(B.fontFamily) ? r.string(W.fontFamily) : ""; fontChanged = true }
        if r.dirty(B.textAlign) {
            switch CuiPaint.TextAlign(rawValue: r.word(W.textAlign)) ?? .start {
            case .center: c.applyTextAlign(.center)
            case .end, .right: c.applyTextAlign(.right)
            case .start, .left: c.applyTextAlign(.left)
            }
        }
        if r.dirty(B.lineHeight) {
            c.applyLineHeight(CGFloat(r.float(W.lineHeight)))
            FrameBatcher.request(self, measure: true)
        }
        if r.dirty(B.placeholder) { placeholderText = r.has(B.placeholder) ? r.string(W.placeholder) : nil; c.applyPlaceholder(placeholderText, color: placeholderColor) }
        if r.dirty(B.placeholderColor) { placeholderColor = r.has(B.placeholderColor) ? UIColor(rgba: r.color(W.placeholderColor)) : nil; c.applyPlaceholder(placeholderText, color: placeholderColor) }
        if r.dirty(B.type) { c.applyInputType(CuiPaint.InputType(rawValue: r.word(W.type)) ?? .text) }
        if r.dirty(B.enterKey) { c.applyEnterKey(r.has(B.enterKey) ? CuiPaint.EnterKey(rawValue: r.word(W.enterKey)) : nil) }
        if r.dirty(B.maxLength) { let m = Int(r.float(W.maxLength)); c.maxLength = m > 0 ? m : nil }
        if r.dirty(B.autocapitalize) { c.applyAutocapitalize(CuiPaint.Autocapitalize(rawValue: r.word(W.autocapitalize)) ?? .sentences) }
        if r.dirty(B.autocorrect) { c.applyAutocorrect(r.bool(W.autocorrect)) }
        if r.dirty(B.keyboardShrink) { keyboardShrink = r.bool(W.keyboardShrink) }
        if r.dirty(B.keyboardDismiss) { keyboardDismiss = r.bool(W.keyboardDismiss) }
        if fontChanged {
            c.applyFont(FontManager.font(family: fontFamily, weight: fontWeight, italic: italic, size: fontSize))
            FrameBatcher.request(self, measure: true)
        }
    }

    func fontChanged() {
        control.applyFont(FontManager.font(family: fontFamily, weight: fontWeight, italic: italic, size: fontSize))
        FrameBatcher.request(self, measure: true)
    }

    override func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        control.measure(width: width, widthMode: widthMode, height: height, heightMode: heightMode)
    }

    /// The padding is the core's: the control draws inside it.
    override func frameApplied() {
        let p = CreatorUI.padding(id)
        control.padding = UIEdgeInsets(top: CGFloat(p.top), left: CGFloat(p.left), bottom: CGFloat(p.bottom), right: CGFloat(p.right))
    }

    // MARK: - the events (posted: outside the editing transaction)

    func dispatchChange(_ value: String) {
        guard !isRemoved, has(TreeEvents.TREE_FLAG_CHANGE) else { return }
        let id = id
        JSThread.post { Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_CHANGE, [.string(value)]) }
    }
    func dispatchSubmit(_ value: String) {
        guard !isRemoved, has(TreeEvents.TREE_FLAG_SUBMIT) else { return }
        let id = id
        JSThread.post { Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_SUBMIT, [.string(value)]) }
    }
    /// The control reports its focus here (the UIKit delegate; a test without a window, where no
    /// first responder exists, drives it directly). The core's focused layer flips synchronously
    /// (a style may depend on it); the root host (the keyboard policy) hears it now, the
    /// listeners posted.
    public func focusChanged(_ focused: Bool) {
        guard !isRemoved else { return }
        isFocused = focused
        CreatorUI.setNodeFocused(id, focused)
        let root = UINode.appRoot as? UIRootHost
        if focused { root?.onInputFocused(self) } else { root?.onInputBlurred(self) }
        let kind = focused ? TreeEvents.TREE_EVENT_FOCUS : TreeEvents.TREE_EVENT_BLUR
        guard has(focused ? TreeEvents.TREE_FLAG_FOCUS : TreeEvents.TREE_FLAG_BLUR) else { return }
        let id = id
        JSThread.post { Core.nodeEvent(id, kind: kind) }
    }

    public override func onRemoved() {
        super.onRemoved()
        TextNodes.remove(self)
    }
}

