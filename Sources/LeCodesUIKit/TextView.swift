// The text node's view: the box (TextView, what BoxPaint paints) holding the label (TextLabel),
// which lays out and draws the text ITSELF with CoreText, line by line — the desktop renderer's
// model (renderers/tgfx ui_paint.cpp paintText), not UILabel's. The reasons: TextKit's placement of
// a fixed line box moved between iOS versions (the baseline shift that compensated one version cut
// the text on the next), a UILabel draws only inside its own bounds, and spans (per-range styles,
// tappable links) are attribute ranges + glyph positions here, which UILabel never exposes.
//
// The model, the same on every host: a paragraph's lines are `lineHeight` tall each (the record's,
// always set: the core resolves `normal` = fontSize × 1.2), the box is lineHeight × lines (the yoga measure),
// and a line's glyphs are centred in the line box by ascent + descent — the CSS half-leading rule
// Android's ExactLineHeightSpan and the desktop apply. A lineHeight SHORTER than the font keeps the
// box at lineHeight and lets the glyphs overflow it, half above and half below, visibly: the label is
// the box grown by that overflow on top and bottom (TextView.layoutSubviews), so nothing is cut.
//
// Wrapping is CTTypesetter's (word breaks, a word longer than the line breaks inside it, `\n` is a
// hard break); lineClamp keeps the first N lines and, unless textOverflow is clip, ends the last one
// with an ellipsis over everything cut. letterSpacing is the kern attribute (after every glyph, the
// CSS / Canvas2D width). Underline / strikethrough are rects at the desktop's positions. The padding
// is the core's (the yoga padding): the label draws inside it, the measure reports the content.
//
// The layout (the CTLines) is computed once per (content, style, width) and reused by the measure
// and the draw; the bitmap is the layer's, redrawn only on a change — a scroll composites it.
//
// Rich text (docs/plans/rich-text-plan.md): a paragraph with inline runs hands the label its leaf
// runs (`runs`, UINodeText collects them) — one attributed string, a font / kern per run and the
// run's index as an attribute, through the SAME typesetter, so wrapping is word-wise across run
// boundaries. The line box stays the paragraph's lineHeight; a line's ascent / descent are the
// maxima over the fonts of the runs it holds (the runs' own fonts, never a fallback face CoreText
// substituted — the plain path's rule) and every run sits on that one baseline by the half-leading
// rule; a run taller than the line box overflows it visibly (verticalOverflow takes the tallest
// run, and the paragraph's own font as a strut, CSS's). Each glyph run draws in its run's color;
// underline / line-through are rects per run in its color at its font's metrics; a run at any depth
// with a backgroundColor gets one rect per line over its pieces, its OWN font's ascent + descent
// around the baseline, all of them under every glyph and decoration, outer runs first. The
// ellipsis of a clamp belongs to the run it cuts — the run of the first character it hides: that
// run's font, color, decoration and highlight. A run's
// fragment on a line is its pieces' x-span by the line's full height (the line box and the glyphs
// overflowing it); TextView routes the press (PressTracker) to the innermost INTERACTIVE run under
// the finger, else an outer one, else the paragraph when it is interactive, else hands the touch on
// as it always did. The model is the web-canvas reference's (renderers/web-canvas core/text.ts).
//
// An image run (an icon in a line, the plan's appendix: rules 9–15) is one placeholder character
// (U+FFFC) with a CTRunDelegate of the image's box: its width advances the line exactly (no kern),
// its ascent / descent are the box's parts above / below the baseline with its centre on the text
// middle, `baseline − xHeight / 2` of the font the icon inherited (CTFontGetXHeight; CSS
// `vertical-align: middle`), and they count in the line's maxima like a piece of a large font. A
// word joiner (U+2060) glues it to a neighbour that is not white space: the icon is one unbreakable
// word character, a space beside it is a break opportunity (CoreText breaks around U+FFFC
// otherwise). The icon is drawn after the glyphs at the delegate run's position, clipped to its
// corner radii, at its opacity: its own backgroundColor, then the bitmap placed by its crop /
// objectFit; no bitmap yet = no bitmap drawn (the box stays reserved). Its fragment for a finger is
// a run's: its x-span by the line's full height.
import CoreText
import LeCodesCore
import UIKit

final class TextView: UIView, PointerTarget {
    weak var node: UINodeText?
    let label: TextLabel
    /// The press of the run under the finger, or of the paragraph when it listens (rule 5).
    private lazy var press = PressTracker(view: self, resolve: { [weak self] p in self?.touchTarget(at: p) },
                                          contains: { [weak self] target, p in
                                              guard let self else { return false }
                                              return self.bounds.contains(self.convert(p, from: UINode.appRoot ?? self)) && self.touchTarget(at: p) === target
                                          })
    /// The pointers that landed on nothing of the text's, handed on the way an unhandled touch always
    /// went: UIKit's up the responder chain (`super`), the scripted pointer's to the nearest pointer
    /// target above (what the root's walk would have found) — a plain text in a button stays the
    /// button's.
    private var passedTouches = Set<ObjectIdentifier>()
    private var passedPointers: [Int32: PointerTarget] = [:]

    init(node: UINodeText) {
        self.node = node
        label = TextLabel()
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        node?.box.layoutSublayers()
        let over = label.verticalOverflow
        label.place(bounds.insetBy(dx: 0, dy: -over))
    }

    /// The box's shadow lives in the parent's layer: it goes where the view goes (BoxShadow.swift).
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        node?.followShadow()
    }

    /// The pointers that landed on the text end with it — its own, and the ones it handed on, at
    /// the target that took them (HeldTouches): UIKit sends no end and no cancel of them.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        HeldTouches.viewLeftWindow(self)
        passedTouches.removeAll()
        passedPointers.removeAll()
    }

    /// The node a finger at a root point presses (UINodeText.touchTarget), nil = not the text's.
    private func touchTarget(at rootPoint: CGPoint) -> UINode? {
        node?.touchTarget(at: label.convert(rootPoint, from: UINode.appRoot ?? self))
    }

    /// Does a finger at a root point land on something of the text's to press (the resolution the
    /// press itself takes)? The keyboard's tap-to-dismiss counts such a point as a control's.
    func takesPress(at rootPoint: CGPoint) -> Bool { touchTarget(at: rootPoint) != nil }

    // MARK: - the pointer (UIKit's touches and the scripted pointer both land here)

    func pointerDown(_ pointerId: Int32, at p: CGPoint) {
        if press.down(pointerId, at: p, pressAfter: 0) {
            HeldTouches.began(pointerId, hit: nil, owner: self)
            return
        }
        var v = superview
        while let cur = v {
            if let target = cur as? (UIView & PointerTarget) {
                passedPointers[pointerId] = target
                target.pointerDown(pointerId, at: p)
                HeldTouches.began(pointerId, hit: self, owner: target)   // it landed on the text: it ends with it
                return
            }
            v = cur.superview
        }
    }
    func pointerMove(_ pointerId: Int32, to p: CGPoint) {
        if let target = passedPointers[pointerId] { target.pointerMove(pointerId, to: p) }
        else if press.holds(pointerId) { press.move(pointerId, to: p) }
    }
    func pointerUp(_ pointerId: Int32, at p: CGPoint) {
        if let target = passedPointers.removeValue(forKey: pointerId) { target.pointerUp(pointerId, at: p) }
        else if press.holds(pointerId) { ownUp(pointerId, at: p) }
    }
    func pointerCancel(_ pointerId: Int32) {
        if let target = passedPointers.removeValue(forKey: pointerId) { target.pointerCancel(pointerId) }
        else if press.holds(pointerId) { ownCancel(pointerId) }
    }
    func pointerLost(_ pointerId: Int32) { press.lose(pointerId) }

    private func ownUp(_ pointerId: Int32, at p: CGPoint) {
        HeldTouches.ended(pointerId)
        press.up(pointerId, at: p)
    }
    private func ownCancel(_ pointerId: Int32) {
        HeldTouches.ended(pointerId)
        press.cancel(pointerId)
    }

    // MARK: - UIKit's touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let delay = press.touchPressDelay
        var passed = Set<UITouch>()
        for t in touches {
            let id = TouchPipeline.pointerId(t)
            if press.down(id, at: rootPoint(of: t), pressAfter: delay) {
                HeldTouches.began(id, hit: t.view, owner: self)
            } else {
                passed.insert(t)
                passedTouches.insert(ObjectIdentifier(t))
            }
        }
        if !passed.isEmpty { super.touchesBegan(passed, with: event) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let passed = split(touches, ending: false) { press.move(TouchPipeline.pointerId($0), to: rootPoint(of: $0)) }
        if !passed.isEmpty { super.touchesMoved(passed, with: event) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let passed = split(touches, ending: true) { ownUp(TouchPipeline.pointerId($0), at: rootPoint(of: $0)) }
        if !passed.isEmpty { super.touchesEnded(passed, with: event) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let passed = split(touches, ending: true) { ownCancel(TouchPipeline.pointerId($0)) }
        if !passed.isEmpty { super.touchesCancelled(passed, with: event) }
    }

    /// The touches handed on at their start (returned, to pass on again); `own` runs for the others.
    private func split(_ touches: Set<UITouch>, ending: Bool, own: (UITouch) -> Void) -> Set<UITouch> {
        var passed = Set<UITouch>()
        for t in touches {
            let key = ObjectIdentifier(t)
            if passedTouches.contains(key) {
                passed.insert(t)
                if ending { passedTouches.remove(key) }
            } else if press.holds(TouchPipeline.pointerId(t)) {
                own(t)
            }
        }
        return passed
    }
}

final class TextLabel: UIView {
    // MARK: - the style (UINodeText writes it from the paint record)

    var content = "" { didSet { if content != oldValue { invalidate() } } }
    var resolvedFont: UIFont = .systemFont(ofSize: 14) { didSet { if resolvedFont != oldValue { invalidate() } } }
    var textColor: UIColor = .white { didSet { setNeedsDisplay() } }
    /// The record's line box, always set: the core resolves `normal` (the node's own fontSize × 1.2)
    /// and every explicit form, and the paint sync precedes the first measure. Starts at the core's
    /// fresh-node value (14 × 1.2); there is no natural-metrics fallback.
    var lineHeight: CGFloat = 14 * 1.2 { didSet { if lineHeight != oldValue { invalidate() } } }
    var letterSpacing: CGFloat = 0 { didSet { if letterSpacing != oldValue { invalidate() } } }
    var textAlignment: NSTextAlignment = .left { didSet { setNeedsDisplay() } }
    var underline = false { didSet { setNeedsDisplay() } }
    var strikethrough = false { didSet { setNeedsDisplay() } }
    /// 0 = every line.
    var lineClamp = 0 { didSet { if lineClamp != oldValue { invalidate() } } }
    /// textOverflow: clip cuts the clamped text, else an ellipsis ends it.
    var clipsOverflow = false { didSet { if clipsOverflow != oldValue { invalidate() } } }
    /// textWrap: how a paragraph breaks into lines (see `lines(maxWidth:)`).
    var textWrap: CuiPaint.TextWrap = .wrap { didSet { if textWrap != oldValue { invalidate() } } }
    /// The core's padding: the text lays out and draws inside it.
    var inset = UIEdgeInsets.zero { didSet { if inset != oldValue { setNeedsDisplay() } } }
    /// The paragraph's leaf runs in order (rich text), nil = the plain string: `content` in the
    /// label's own style. A change of a run's string, font or spacing re-lays the paragraph; of its
    /// color, decoration or highlight only redraws it (the glyphs take their color from the context).
    var runs: [TextRun]? {
        didSet {
            if TextRun.sameLayout(runs, oldValue) { if runs != oldValue { setNeedsDisplay() } } else { invalidate() }
        }
    }
    /// The runs' highlights in pre-order (outer runs first), each over a range of `runs`.
    var highlights: [TextHighlight] = [] { didSet { if highlights != oldValue { setNeedsDisplay() } } }
    /// The runs when there is anything to draw from them; nil = the plain path.
    private var rich: [TextRun]? {
        guard let runs, !runs.isEmpty else { return nil }
        return runs
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        layer.contentsScale = UIScreen.main.scale
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let s = window?.screen.scale, s > 0, layer.contentsScale != s { layer.contentsScale = s; setNeedsDisplay() }
    }

    // MARK: - the metrics

    /// The line box height: the record's (see `lineHeight`).
    var effectiveLineHeight: CGFloat { lineHeight }

    /// How far a line's glyphs stick out of its line box on EACH side: 0 unless the lineHeight is
    /// shorter than the font's ascent + descent — with runs, the tallest ascent + the deepest descent
    /// of them all and of the strut (a bound on every line's maxima).
    var verticalOverflow: CGFloat {
        guard let runs = rich else { return max(0, (resolvedFont.ascender - resolvedFont.descender - effectiveLineHeight) / 2) }
        var ascent = resolvedFont.ascender, descent = -resolvedFont.descender
        for r in runs {
            let m = metrics(of: r)
            ascent = max(ascent, m.ascent)
            descent = max(descent, m.descent)
        }
        return max(0, (ascent + descent - effectiveLineHeight) / 2)
    }

    /// A piece's extent above / below the baseline (positive = away from it): a text run's font's; an
    /// icon's box centred at `baseline − xHeight / 2` of the font it inherited (rule 11).
    func metrics(of r: TextRun) -> (ascent: CGFloat, descent: CGFloat) {
        guard let piece = r.image else { return (r.font.ascender, -r.font.descender) }
        let middle = CTFontGetXHeight(r.font as CTFont) / 2
        return (piece.size.height / 2 + middle, piece.size.height / 2 - middle)
    }

    // MARK: - the layout

    struct Line {
        let line: CTLine
        /// The typographic width less the trailing whitespace: what alignment and decorations use.
        let width: CGFloat
        /// The line's ascent and descent (positive): the font's; with runs, the maxima over the
        /// fonts of the runs it holds and the paragraph's own font, the strut (rule 3).
        let ascent: CGFloat
        let descent: CGFloat
        /// With runs: where each run's glyphs lie on the line, left to right.
        let spans: [Span]
    }

    /// One run's glyph extent on a line: [x0, x1) from the line's origin, cut at its visible width
    /// (trailing spaces carry no highlight or decoration); the glyph runs CoreText split one run
    /// into (a fallback face, a direction) merged back.
    struct Span {
        let run: Int
        var x0: CGFloat
        var x1: CGFloat
        /// An icon's placeholder (its box), not glyphs: never decorated — an ellipsis cut at an icon
        /// is glyphs, in the icon's inherited text style.
        var isImage = false
    }

    /// The attribute carrying a character's run index (rich text), and the one marking an ellipsis.
    static let runKey = NSAttributedString.Key("lecodes.run")
    private static let ellipsisKey = NSAttributedString.Key("lecodes.ellipsis")
    private static let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)

    private static func runIndex(of glyphRun: CTRun) -> Int? {
        (CTRunGetAttributes(glyphRun) as NSDictionary)[runKey.rawValue] as? Int
    }
    /// The glyph run is an image's placeholder (it carries the box's run delegate).
    private static func isPlaceholder(_ glyphRun: CTRun) -> Bool {
        (CTRunGetAttributes(glyphRun) as NSDictionary)[delegateKey.rawValue] != nil
    }

    /// A Line for `line`: the plain path's metrics are the font's, a rich line's the maxima over the
    /// fonts of its pieces (a hard break is none) and the strut, plus its spans.
    private func makeLine(_ line: CTLine, in text: NSAttributedString) -> Line {
        let width = Self.visibleWidth(line)
        guard let runs = rich else {
            return Line(line: line, width: width, ascent: resolvedFont.ascender, descent: -resolvedFont.descender, spans: [])
        }
        var ascent = resolvedFont.ascender, descent = -resolvedFont.descender
        var spans: [Span] = []
        let ns = text.string as NSString
        for glyphRun in CTLineGetGlyphRuns(line) as! [CTRun] {
            guard let i = Self.runIndex(of: glyphRun), i < runs.count else { continue }
            // A joiner between two icons carries an image's index and no box: nothing of its own.
            if runs[i].image != nil, !Self.isPlaceholder(glyphRun), (CTRunGetAttributes(glyphRun) as NSDictionary)[Self.ellipsisKey.rawValue] == nil { continue }
            let range = CTRunGetStringRange(glyphRun)
            let onlyBreaks = range.length > 0 && range.location + range.length <= ns.length
                && (range.location..<(range.location + range.length)).allSatisfy { ns.character(at: $0) == 0x0A }
            if !onlyBreaks {
                // An ellipsis cut at an icon is text in the icon's text style; a placeholder, the box.
                let m = Self.isPlaceholder(glyphRun) ? metrics(of: runs[i]) : (runs[i].font.ascender, -runs[i].font.descender)
                ascent = max(ascent, m.0)
                descent = max(descent, m.1)
            }
            guard CTRunGetGlyphCount(glyphRun) > 0 else { continue }
            var origin = CGPoint.zero
            CTRunGetPositions(glyphRun, CFRange(location: 0, length: 1), &origin)
            let x0 = origin.x
            let x1 = min(width, x0 + CGFloat(CTRunGetTypographicBounds(glyphRun, CFRange(location: 0, length: 0), nil, nil, nil)))
            guard x1 > x0 else { continue }
            let isImage = Self.isPlaceholder(glyphRun)
            if let last = spans.last, last.run == i, last.isImage == isImage, abs(last.x1 - x0) < 0.5 { spans[spans.count - 1].x1 = max(last.x1, x1) }
            else { spans.append(Span(run: i, x0: x0, x1: x1, isImage: isImage)) }
        }
        return Line(line: line, width: width, ascent: ascent, descent: descent, spans: spans)
    }

    private var cachedLines: [Line] = []
    private var cachedWidth: CGFloat = -1
    private var attributed: NSAttributedString?

    private func invalidate() {
        cachedWidth = -1
        cachedLines = []
        attributed = nil
        setNeedsDisplay()
        // The overflow (verticalOverflow) moved with the font or the line height: the box's
        // layoutSubviews must re-fit the label around it even when the box's frame does not
        // change — a face that arrives after the first layout (FontManager) used to leave the
        // label at the system font's overflow, cutting the new face's descenders.
        superview?.setNeedsLayout()
    }

    private func attributedString() -> NSAttributedString {
        if let a = attributed { return a }
        if let runs = rich {
            let s = NSMutableAttributedString()
            var afterImage = false   // the last character appended is an icon's
            for (i, r) in runs.enumerated() where !r.text.isEmpty {
                var attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): r.font as CTFont,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                    Self.runKey: i,
                ]
                if let piece = r.image {
                    // Glued to a word on its left (rule 11); the joiner is the neighbour's, never a box.
                    if s.length > 0, !Self.isSpace(s.string.utf16.last!) {
                        s.append(NSAttributedString(string: "\u{2060}", attributes: Self.textAttributes(s, at: s.length - 1)))
                    }
                    let m = metrics(of: r)
                    if let d = InlineBox.delegate(width: piece.size.width, ascent: max(0, m.ascent), descent: max(0, m.descent)) {
                        attrs[Self.delegateKey] = d
                    }
                    s.append(NSAttributedString(string: r.text, attributes: attrs))
                    afterImage = true
                    continue
                }
                if r.letterSpacing != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = r.letterSpacing }
                if afterImage, let first = r.text.utf16.first, !Self.isSpace(first) {   // glued to a word on its right
                    s.append(NSAttributedString(string: "\u{2060}", attributes: attrs))
                }
                s.append(NSAttributedString(string: r.text, attributes: attrs))
                afterImage = false
            }
            attributed = s
            return s
        }
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): resolvedFont as CTFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if letterSpacing != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = letterSpacing }
        let a = NSAttributedString(string: content, attributes: attrs)
        attributed = a
        return a
    }

    /// White space a line may break at (an icon is glued to anything else).
    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x3000
    }

    /// The attributes of the character at `index` as TEXT: an icon's placeholder without its box —
    /// what an ellipsis or a joiner beside it is drawn in.
    private static func textAttributes(_ text: NSAttributedString, at index: Int) -> [NSAttributedString.Key: Any] {
        var attrs = text.attributes(at: index, effectiveRange: nil)
        attrs[delegateKey] = nil
        return attrs
    }

    private static func visibleWidth(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
    }

    /// The lines in a box `maxWidth` wide (infinite = no wrapping), clamped; memoised on the width.
    /// `textWrap` decides the soft breaks (`breakRanges`); `nowrap` takes none at any width, and a
    /// line of its wider than a finite box ends with an ellipsis (clip lets it run past) — the
    /// measure asks with an infinite width, so the box is the whole line and nothing is fitted there.
    func lines(maxWidth: CGFloat) -> [Line] {
        if cachedWidth == maxWidth { return cachedLines }
        let text = attributedString()
        let length = text.length
        var out: [Line] = []
        if length > 0 {
            let typesetter = CTTypesetterCreateWithAttributedString(text)
            let nsText = text.string as NSString
            let nowrap = textWrap == .nowrap
            let width = maxWidth.isFinite && maxWidth > 0 && !nowrap ? Double(maxWidth) : Double.greatestFiniteMagnitude
            let ranges = breakRanges(typesetter, nsText, length: length, width: width)
            let cut = lineClamp > 0 && ranges.count > lineClamp
            for (i, range) in ranges.enumerated() {
                if cut && i == lineClamp - 1 {
                    // The last kept line carries the REST of the text so the ellipsis stands for all of it.
                    var last = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: length - range.location))
                    if clipsOverflow {
                        last = CTTypesetterCreateLine(typesetter, range)
                    } else if maxWidth.isFinite {
                        last = truncated(last, text: text, at: range.location, width: maxWidth)
                    } else {
                        // Unconstrained (intrinsic): nothing to fit into — the ellipsis just ends the line.
                        last = ellipsisLine(text, range: range)
                    }
                    out.append(makeLine(last, in: text))
                    break
                }
                var line = CTTypesetterCreateLine(typesetter, range)
                if nowrap, !clipsOverflow, maxWidth.isFinite, Self.visibleWidth(line) > maxWidth {
                    line = truncated(line, text: text, at: range.location, width: maxWidth)
                }
                out.append(makeLine(line, in: text))
            }
            // A trailing hard break opens an empty last line (the desktop's wrapText does the same).
            if nsText.hasSuffix("\n"), lineClamp == 0 || out.count < lineClamp {
                let empty = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: text.attributes(at: length - 1, effectiveRange: nil)))
                out.append(makeLine(empty, in: text))
            }
        }
        cachedLines = out
        cachedWidth = maxWidth
        return out
    }

    /// `line` ended with "…" inside `width` (CoreText's end truncation). With runs the ellipsis takes
    /// the run it cuts — the run of the first character it hides (rule 3): cut once with the line
    /// start's run, and again with the hidden one's when that is another run.
    private func truncated(_ line: CTLine, text: NSAttributedString, at index: Int, width: CGFloat) -> CTLine {
        guard rich != nil else {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: text.attributes(at: index, effectiveRange: nil)))
            return CTLineCreateTruncatedLine(line, Double(width), .end, token) ?? line
        }
        let cut = { (from: Int) -> CTLine in
            var attrs = Self.textAttributes(text, at: from)
            attrs[Self.ellipsisKey] = true
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attrs))
            return CTLineCreateTruncatedLine(line, Double(width), .end, token) ?? line
        }
        let first = cut(index)
        guard let hidden = Self.firstHiddenIndex(first, in: text), hidden < text.length,
              text.attribute(Self.runKey, at: hidden, effectiveRange: nil) as? Int != text.attribute(Self.runKey, at: index, effectiveRange: nil) as? Int
        else { return first }
        return cut(hidden)
    }

    /// The string index just past what a truncated line keeps (nil when nothing was cut) — past a
    /// joiner there, which is no character of its own (the icon it glues is the one hidden).
    private static func firstHiddenIndex(_ line: CTLine, in text: NSAttributedString) -> Int? {
        var end = -1, cut = false
        for glyphRun in CTLineGetGlyphRuns(line) as! [CTRun] {
            if (CTRunGetAttributes(glyphRun) as NSDictionary)[ellipsisKey.rawValue] != nil { cut = true; continue }
            let r = CTRunGetStringRange(glyphRun)
            end = max(end, r.location + r.length)
        }
        guard cut, end >= 0 else { return nil }
        let ns = text.string as NSString
        while end < ns.length - 1, ns.character(at: end) == 0x2060 { end += 1 }
        return end
    }

    /// The text of `range` (less its trailing spaces and hard break) followed by "…", as one line.
    private func ellipsisLine(_ text: NSAttributedString, range: CFRange) -> CTLine {
        let s = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: range.location, length: range.length)))
        let ns = s.string as NSString
        var end = ns.length
        while end > 0, let scalar = Unicode.Scalar(ns.character(at: end - 1)), scalar == "\n" || scalar == " " || scalar == "\t" { end -= 1 }
        if end < ns.length { s.deleteCharacters(in: NSRange(location: end, length: ns.length - end)) }
        // With runs: in the run it cuts — the next line's first character's.
        let tokenAt = rich != nil ? min(range.location + range.length, text.length - 1) : range.location
        s.append(NSAttributedString(string: "\u{2026}", attributes: Self.textAttributes(text, at: tokenAt)))
        return CTLineCreateWithAttributedString(s)
    }

    /// `balance` evens out paragraphs of up to this many lines (CSS limits it the same way).
    private static let balanceMaxLines = 10

    /// The line ranges of the text at `width` per `textWrap`: CTTypesetter's greedy breaks (a hard
    /// break ends a line in every mode), reworked per paragraph for balance / pretty by the desktop's
    /// rules (renderers/tgfx ui_text.cpp): balance = the narrowest whole-pt width that keeps the
    /// paragraph's line count (paragraphs of 2…10 lines), pretty = the last word of the line before
    /// moves down when the last line is one word and the pair fits. A paragraph the clamp cuts stays
    /// greedy, and so does everything after.
    private func breakRanges(_ typesetter: CTTypesetter, _ nsText: NSString, length: Int, width: Double) -> [CFRange] {
        var out: [CFRange] = []
        var shape = (textWrap == .balance || textWrap == .pretty) && width < Double.greatestFiniteMagnitude
        var index = 0
        while index < length {
            // The paragraph: up to and including the next hard break.
            let nl = nsText.range(of: "\n", options: [], range: NSRange(location: index, length: length - index))
            let end = nl.location == NSNotFound ? length : nl.location + 1
            var lines = Self.greedy(typesetter, from: index, to: end, width: width)
            if shape {
                if lineClamp > 0, out.count + lines.count > lineClamp { shape = false }
                else if textWrap == .balance { lines = balance(typesetter, nsText, lines, from: index, to: end, width: width) }
                else { lines = pretty(typesetter, nsText, lines, width: width) }
            }
            out.append(contentsOf: lines)
            index = end
        }
        return out
    }

    /// The typesetter's greedy breaks of `[start, end)` at `width`.
    private static func greedy(_ typesetter: CTTypesetter, from start: Int, to end: Int, width: Double) -> [CFRange] {
        var out: [CFRange] = []
        var index = start
        while index < end {
            let count = max(1, min(end - index, CTTypesetterSuggestLineBreak(typesetter, index, width)))
            out.append(CFRange(location: index, length: count))
            index += count
        }
        return out
    }

    /// A binary search over whole points: the line count never grows with the width, and from the
    /// widest word up no word is broken, so the search only moves breaks between words. Whole points
    /// keep the measure (searching down from the constraint) and the draw (down from the box, a width
    /// in between) on the same breaks.
    private func balance(_ typesetter: CTTypesetter, _ nsText: NSString, _ greedy: [CFRange], from start: Int, to end: Int, width: Double) -> [CFRange] {
        let n = greedy.count
        if n < 2 || n > Self.balanceMaxLines { return greedy }
        let count = { (w: Int) -> Int in Self.greedy(typesetter, from: start, to: end, width: Double(w)).count }
        var hi = Int(width.rounded(.down))
        if count(hi) != n { return greedy }
        var lo = 0
        var wordStart = start
        while wordStart < end {
            let space = nsText.range(of: " ", options: [], range: NSRange(location: wordStart, length: end - wordStart))
            let wordEnd = space.location == NSNotFound ? end : space.location
            if wordEnd > wordStart {
                let word = CTTypesetterCreateLine(typesetter, CFRange(location: wordStart, length: wordEnd - wordStart))
                lo = max(lo, Int(Self.visibleWidth(word).rounded(.up)))
            }
            wordStart = wordEnd + 1
        }
        if lo >= hi { return greedy }
        if count(lo) == n { hi = lo }
        else {
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if count(mid) == n { hi = mid } else { lo = mid }
            }
        }
        return Self.greedy(typesetter, from: start, to: end, width: Double(hi))
    }

    private func pretty(_ typesetter: CTTypesetter, _ nsText: NSString, _ greedy: [CFRange], width: Double) -> [CFRange] {
        let n = greedy.count
        if n < 2 { return greedy }
        let lastRange = greedy[n - 1], prevRange = greedy[n - 2]
        let last = nsText.substring(with: NSRange(location: lastRange.location, length: lastRange.length)).trimmingCharacters(in: .whitespacesAndNewlines)
        if last.isEmpty || last.contains(" ") { return greedy }
        // The line before, less its trailing spaces: its last space is the new break.
        let prev = nsText.substring(with: NSRange(location: prevRange.location, length: prevRange.length)) as NSString
        var prevEnd = prev.length
        while prevEnd > 0, prev.character(at: prevEnd - 1) == 0x20 { prevEnd -= 1 }
        let cut = prev.range(of: " ", options: .backwards, range: NSRange(location: 0, length: prevEnd)).location
        if cut == NSNotFound || cut == 0 { return greedy }
        let joinedStart = prevRange.location + cut + 1
        let joined = CFRange(location: joinedStart, length: lastRange.location + lastRange.length - joinedStart)
        if Self.visibleWidth(CTTypesetterCreateLine(typesetter, joined)) > CGFloat(width) { return greedy }
        var out = Array(greedy.dropLast(2))
        out.append(CFRange(location: prevRange.location, length: cut + 1))
        out.append(joined)
        return out
    }

    /// The yoga measure: the widest line and lineHeight × lines within the width constraint (mode
    /// 0 / NaN = unconstrained). The height constraint never cuts lines: overflow is visible, as CSS.
    func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        let constraint = widthMode == 0 || width.isNaN ? CGFloat.infinity : CGFloat(width)
        // nowrap: the box is the intrinsic width — the lines are measured unconstrained.
        let ls = lines(maxWidth: textWrap == .nowrap ? .infinity : constraint)
        if ls.isEmpty { return .zero }
        let widest = ls.reduce(CGFloat(0)) { max($0, $1.width) }
        let scale = layer.contentsScale > 0 ? layer.contentsScale : 1
        return CGSize(width: (widest * scale).rounded(.up) / scale, height: CGFloat(ls.count) * effectiveLineHeight)
    }

    // MARK: - the draw

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if let runs = rich { drawRuns(ctx, runs); return }
        let over = verticalOverflow
        let left = inset.left
        let top = over + inset.top
        let contentWidth = max(0, bounds.width - inset.left - inset.right)
        let ls = lines(maxWidth: contentWidth)
        if ls.isEmpty { return }
        let lh = effectiveLineHeight
        let ascent = resolvedFont.ascender, descent = -resolvedFont.descender
        let color = textColor.cgColor
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        // CoreText draws in a y-up space: flip once, then every baseline is bounds.height − y.
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        let thickness = max(1, resolvedFont.pointSize / 14)
        for (i, l) in ls.enumerated() {
            let lineTop = top + CGFloat(i) * lh
            let baseline = lineTop + (lh - (ascent + descent)) / 2 + ascent
            let x: CGFloat
            switch textAlignment {
            case .center: x = left + (contentWidth - l.width) / 2
            case .right: x = left + contentWidth - l.width
            default: x = left
            }
            ctx.textPosition = CGPoint(x: x, y: bounds.height - baseline)
            CTLineDraw(l.line, ctx)
            if underline || strikethrough {
                let y = underline ? baseline + thickness : baseline - resolvedFont.pointSize * 0.3
                ctx.fill(CGRect(x: x, y: bounds.height - y - thickness, width: l.width, height: thickness))
            }
        }
        ctx.restoreGState()
    }

    /// The x of a line's origin in the label: the alignment inside the content box.
    private func lineX(_ l: Line, contentWidth: CGFloat) -> CGFloat {
        switch textAlignment {
        case .center: return inset.left + (contentWidth - l.width) / 2
        case .right: return inset.left + contentWidth - l.width
        default: return inset.left
        }
    }

    /// The rich draw: every highlight first (rule 4: under all glyphs and decoration, over the
    /// paragraph's box; outer runs first) — per line one rect over the run's pieces, its own font's
    /// ascent + descent around the baseline — then line by line each glyph run in its run's color and
    /// each run's decoration at its own font's metrics (the plain path's positions), then the icons.
    private func drawRuns(_ ctx: CGContext, _ runs: [TextRun]) {
        let contentWidth = max(0, bounds.width - inset.left - inset.right)
        let ls = lines(maxWidth: contentWidth)
        if ls.isEmpty { return }
        let h = bounds.height
        // One baseline per line: the half-leading rule against the line's maxima.
        let origins = ls.enumerated().map { i, l in CGPoint(x: lineX(l, contentWidth: contentWidth), y: baselineY(i, l)) }
        ctx.saveGState()
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        for hl in highlights {
            ctx.setFillColor(hl.color.cgColor)
            for (l, o) in zip(ls, origins) {
                guard let x = Self.extent(of: hl.runs, on: l) else { continue }
                let f = hl.font
                ctx.fill(CGRect(x: o.x + x.lowerBound, y: h - (o.y - f.descender), width: x.upperBound - x.lowerBound, height: f.ascender - f.descender))
            }
        }
        for (l, o) in zip(ls, origins) {
            for glyphRun in CTLineGetGlyphRuns(l.line) as! [CTRun] {
                if Self.isPlaceholder(glyphRun) { continue }   // an icon: its bitmap, below
                let i = Self.runIndex(of: glyphRun) ?? -1
                ctx.setFillColor((i >= 0 && i < runs.count ? runs[i].color : textColor).cgColor)
                ctx.textPosition = CGPoint(x: o.x, y: h - o.y)
                CTRunDraw(glyphRun, ctx, CFRange(location: 0, length: 0))
            }
            for s in l.spans where runs[s.run].decoration != .none && !s.isImage {   // an icon: a gap in an outer underline
                let r = runs[s.run]
                let thickness = max(1, r.font.pointSize / 14)
                let y = r.decoration == .underline ? o.y + thickness : o.y - r.font.pointSize * 0.3
                ctx.setFillColor(r.color.cgColor)
                ctx.fill(CGRect(x: o.x + s.x0, y: h - y - thickness, width: s.x1 - s.x0, height: thickness))
            }
        }
        ctx.restoreGState()
        // The icons (rule 12), in the label's own y-down space, as an image draws itself: clipped to
        // its corner radii (the one box shape it keeps), its own backgroundColor, the bitmap where
        // its crop / objectFit put it, all at its opacity as one group.
        for (i, box) in placedImages(ls, origins) {
            guard let piece = runs[i].image, piece.opacity > 0, piece.background != nil || piece.bitmap != nil else { continue }
            ctx.saveGState()
            let c = piece.radius
            var corners: CACornerMask = []
            if c.topLeft > 0 { corners.insert(.layerMinXMinYCorner) }
            if c.topRight > 0 { corners.insert(.layerMaxXMinYCorner) }
            if c.bottomRight > 0 { corners.insert(.layerMaxXMaxYCorner) }
            if c.bottomLeft > 0 { corners.insert(.layerMinXMaxYCorner) }
            ctx.addPath(BoxShadows.roundedRect(box, radius: max(c.topLeft, c.topRight, c.bottomRight, c.bottomLeft), corners: corners))
            ctx.clip()
            let group = piece.opacity < 1
            if group {
                ctx.setAlpha(piece.opacity)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            if let bg = piece.background {
                ctx.setFillColor(bg.cgColor)
                ctx.fill(box)
            }
            if let bitmap = piece.bitmap, let content = piece.content {
                bitmap.draw(in: content.offsetBy(dx: box.minX, dy: box.minY))
            }
            if group { ctx.endTransparencyLayer() }
            ctx.restoreGState()
        }
    }

    /// The icons of the laid-out lines: each one's leaf index and its box in the label — its width
    /// from the placeholder's position, its centre on the text middle (rule 11).
    private func placedImages(_ ls: [Line], _ origins: [CGPoint]) -> [(run: Int, box: CGRect)] {
        guard let runs = rich else { return [] }
        var out: [(run: Int, box: CGRect)] = []
        for (l, o) in zip(ls, origins) {
            for glyphRun in CTLineGetGlyphRuns(l.line) as! [CTRun] where Self.isPlaceholder(glyphRun) {
                guard let i = Self.runIndex(of: glyphRun), i < runs.count, let piece = runs[i].image else { continue }
                var at = CGPoint.zero
                CTRunGetPositions(glyphRun, CFRange(location: 0, length: 1), &at)
                let m = metrics(of: runs[i])
                out.append((i, CGRect(x: o.x + at.x, y: o.y - m.ascent, width: piece.size.width, height: piece.size.height)))
            }
        }
        return out
    }

    /// The drawn box of the icon at leaf `run` (label coordinates), nil when it is not on a line (the
    /// clamp dropped it).
    func imageBox(ofRun run: Int) -> CGRect? {
        let contentWidth = max(0, bounds.width - inset.left - inset.right)
        let ls = lines(maxWidth: contentWidth)
        let origins = ls.enumerated().map { i, l in CGPoint(x: lineX(l, contentWidth: contentWidth), y: baselineY(i, l)) }
        return placedImages(ls, origins).first { $0.run == run }?.box
    }

    /// Line `i`'s baseline in the label: the half-leading rule against the line's maxima (rule 3).
    func baselineY(_ i: Int, _ l: Line) -> CGFloat {
        let lh = effectiveLineHeight
        return verticalOverflow + inset.top + CGFloat(i) * lh + (lh - (l.ascent + l.descent)) / 2 + l.ascent
    }

    // MARK: - hit-testing the text

    /// The pieces' x-span of the runs in `range` on a line (from the line's origin), nil for none.
    private static func extent(of range: Range<Int>, on l: Line) -> ClosedRange<CGFloat>? {
        var x0 = CGFloat.infinity, x1 = -CGFloat.infinity
        for s in l.spans where range.contains(s.run) {
            x0 = min(x0, s.x0)
            x1 = max(x1, s.x1)
        }
        return x0 < x1 ? x0...x1 : nil
    }

    /// Line `i`'s full height in the label: its box and the glyphs overflowing it,
    /// [min(top, baseline − A), max(top + lineHeight, baseline + D)].
    private func fullHeight(_ i: Int, _ l: Line) -> ClosedRange<CGFloat> {
        let top = verticalOverflow + inset.top + CGFloat(i) * effectiveLineHeight
        let baseline = baselineY(i, l)
        return min(top, baseline - l.ascent)...max(top + effectiveLineHeight, baseline + l.descent)
    }

    /// The run whose piece is under `point` (label coordinates, rich text only): a line whose full
    /// height holds the point (its own box first, where lines overlap), then the glyph extents of its
    /// runs (an icon's: its box's x-span) — the ellipsis included, a run boundary exact; nil between
    /// or past the pieces.
    func runIndex(at point: CGPoint) -> Int? {
        guard rich != nil else { return nil }
        let contentWidth = max(0, bounds.width - inset.left - inset.right)
        let ls = lines(maxWidth: contentWidth)
        let own = Int(((point.y - verticalOverflow - inset.top) / effectiveLineHeight).rounded(.down))
        let order = (own >= 0 && own < ls.count ? [own] : []) + ls.indices.filter { $0 != own }
        for i in order where fullHeight(i, ls[i]).contains(point.y) {
            let x = point.x - lineX(ls[i], contentWidth: contentWidth)
            if let hit = ls[i].spans.first(where: { x >= $0.x0 && x < $0.x1 }) { return hit.run }
        }
        return nil
    }

    /// The bounding box of the fragments of the runs in `range` (label coordinates): per line their
    /// pieces' x-span by the line's full height (an icon's too: rule 13); a range the clamp dropped
    /// is a zero rect at the content origin.
    func fragmentsRect(of range: Range<Int>) -> CGRect {
        let contentWidth = max(0, bounds.width - inset.left - inset.right)
        var out = CGRect.null
        for (i, l) in lines(maxWidth: contentWidth).enumerated() {
            guard let x = Self.extent(of: range, on: l) else { continue }
            let y = fullHeight(i, l), ox = lineX(l, contentWidth: contentWidth)
            out = out.union(CGRect(x: ox + x.lowerBound, y: y.lowerBound, width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound))
        }
        return out.isNull ? CGRect(x: inset.left, y: verticalOverflow + inset.top, width: 0, height: 0) : out
    }

    /// The character index under `point` (label coordinates), nil off the lines.
    func characterIndex(at point: CGPoint) -> Int? {
        let contentWidth = max(0, bounds.width - inset.left - inset.right)
        let ls = lines(maxWidth: contentWidth)
        let lh = effectiveLineHeight
        let top = verticalOverflow + inset.top
        let i = Int(((point.y - top) / lh).rounded(.down))
        guard i >= 0, i < ls.count else { return nil }
        let l = ls[i]
        let x: CGFloat
        switch textAlignment {
        case .center: x = inset.left + (contentWidth - l.width) / 2
        case .right: x = inset.left + contentWidth - l.width
        default: x = inset.left
        }
        guard point.x >= x, point.x <= x + l.width else { return nil }
        let idx = CTLineGetStringIndexForPosition(l.line, CGPoint(x: point.x - x, y: 0))
        return idx == kCFNotFound ? nil : idx
    }
}

/// One leaf run of a paragraph, in order (UINodeText collects them): its string and its style. The
/// layout half (string, font, spacing) re-lays the paragraph; the paint half only redraws it.
struct TextRun: Equatable {
    enum Decoration { case none, underline, lineThrough }
    var text: String
    var font: UIFont
    var letterSpacing: CGFloat
    /// The run's color, its opacity (and its run ancestors') folded in.
    var color: UIColor
    var decoration: Decoration
    /// The leaf's node id: what a finger on its glyphs presses (through the runs that listen).
    var node: Int
    /// An image run (rules 9–12): its placeholder's box and what draws in it; nil for text. Its
    /// `font` / `color` are the text style of the run holding it (an ellipsis cutting at it).
    var image: ImagePiece? = nil

    static func sameLayout(_ a: [TextRun]?, _ b: [TextRun]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return a.count == b.count && zip(a, b).allSatisfy {
                $0.text == $1.text && $0.font == $1.font && $0.letterSpacing == $1.letterSpacing && $0.image?.size == $1.image?.size
            }
        default: return false
        }
    }
}

/// An image run's piece: the box (rule 10, points, not rounded) the line reserves, and the paint
/// half — where the whole picture lands in the box (its crop / objectFit; nil while its size is not
/// known), the bitmap for that (nil until it arrives: no bitmap drawn, the box kept), the image's own
/// backgroundColor under it, its opacity (× its run ancestors'), the corner radii it is clipped to.
/// A change of the box re-lays the paragraph; of the rest only redraws it.
struct ImagePiece: Equatable {
    var size: CGSize
    var content: CGRect?
    var bitmap: UIImage?
    var background: UIColor?
    var opacity: CGFloat
    var radius: Paint.Corners

    static func == (a: ImagePiece, b: ImagePiece) -> Bool {
        a.size == b.size && a.content == b.content && a.bitmap === b.bitmap && a.background == b.background
            && a.opacity == b.opacity && a.radius == b.radius
    }
}

/// The box of an icon's placeholder for its run delegate: the advance and the parts above / below
/// the baseline, retained by the delegate for as long as CoreText holds it.
final class InlineBox {
    let width: CGFloat, ascent: CGFloat, descent: CGFloat
    private init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }

    static func delegate(width: CGFloat, ascent: CGFloat, descent: CGFloat) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { Unmanaged<InlineBox>.fromOpaque($0).release() },
            getAscent: { Unmanaged<InlineBox>.fromOpaque($0).takeUnretainedValue().ascent },
            getDescent: { Unmanaged<InlineBox>.fromOpaque($0).takeUnretainedValue().descent },
            getWidth: { Unmanaged<InlineBox>.fromOpaque($0).takeUnretainedValue().width })
        let box = Unmanaged.passRetained(InlineBox(width: width, ascent: ascent, descent: descent))
        guard let d = CTRunDelegateCreate(&callbacks, box.toOpaque()) else {
            box.release()
            return nil
        }
        return d
    }
}

/// A run's backgroundColor (any depth): per line one rect over the pieces of its leaves (`runs`, a
/// range of the label's runs — a run's leaves are contiguous in pre-order), its own font's ascent +
/// descent around the baseline, its opacity (and its run ancestors') folded into the color.
struct TextHighlight: Equatable {
    var color: UIColor
    var font: UIFont
    var runs: Range<Int>
}
