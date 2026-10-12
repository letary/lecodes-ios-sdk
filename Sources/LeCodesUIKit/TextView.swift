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
import CoreText
import LeCodesCore
import UIKit

final class TextView: UIView {
    weak var node: UINodeText?
    let label: TextLabel

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
    /// shorter than the font's ascent + descent.
    var verticalOverflow: CGFloat {
        max(0, (resolvedFont.ascender - resolvedFont.descender - effectiveLineHeight) / 2)
    }

    // MARK: - the layout

    struct Line {
        let line: CTLine
        /// The typographic width less the trailing whitespace: what alignment and decorations use.
        let width: CGFloat
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
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): resolvedFont as CTFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if letterSpacing != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = letterSpacing }
        let a = NSAttributedString(string: content, attributes: attrs)
        attributed = a
        return a
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
                    out.append(Line(line: last, width: Self.visibleWidth(last)))
                    break
                }
                var line = CTTypesetterCreateLine(typesetter, range)
                if nowrap, !clipsOverflow, maxWidth.isFinite, Self.visibleWidth(line) > maxWidth {
                    line = truncated(line, text: text, at: range.location, width: maxWidth)
                }
                out.append(Line(line: line, width: Self.visibleWidth(line)))
            }
            // A trailing hard break opens an empty last line (the desktop's wrapText does the same).
            if nsText.hasSuffix("\n"), lineClamp == 0 || out.count < lineClamp {
                let empty = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: text.attributes(at: length - 1, effectiveRange: nil)))
                out.append(Line(line: empty, width: 0))
            }
        }
        cachedLines = out
        cachedWidth = maxWidth
        return out
    }

    /// `line` ended with "…" inside `width` (CoreText's end truncation).
    private func truncated(_ line: CTLine, text: NSAttributedString, at index: Int, width: CGFloat) -> CTLine {
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: text.attributes(at: index, effectiveRange: nil)))
        return CTLineCreateTruncatedLine(line, Double(width), .end, token) ?? line
    }

    /// The text of `range` (less its trailing spaces and hard break) followed by "…", as one line.
    private func ellipsisLine(_ text: NSAttributedString, range: CFRange) -> CTLine {
        let s = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: range.location, length: range.length)))
        let ns = s.string as NSString
        var end = ns.length
        while end > 0, let scalar = Unicode.Scalar(ns.character(at: end - 1)), scalar == "\n" || scalar == " " || scalar == "\t" { end -= 1 }
        if end < ns.length { s.deleteCharacters(in: NSRange(location: end, length: ns.length - end)) }
        s.append(NSAttributedString(string: "\u{2026}", attributes: text.attributes(at: range.location, effectiveRange: nil)))
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

    // MARK: - hit-testing the text (the spans to come)

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
