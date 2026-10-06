// Text on Apple: the default font hook (a CSS family → a CTFont) and TextLine, the one line the
// painter draws and a host measures — the SAME CTLine, so measureText and the painted width agree.
import CoreGraphics
import CoreText
import Foundation
import AnyCanvasSpec

public enum Fonts {
    /// CSS generic families that mean "the platform's font of that kind".
    static let generic: [String: String?] = [
        "": nil, "sans-serif": nil, "system-ui": nil, "ui-sans-serif": nil, "ui-rounded": nil, "emoji": nil, "math": nil, "fangsong": nil,
        "serif": "Times New Roman", "ui-serif": "Times New Roman",
        "monospace": "Menlo", "ui-monospace": "Menlo",
        "cursive": "Snell Roundhand", "fantasy": "Papyrus",
    ]

    /// CSS weight (100..900) → CoreText's weight trait (−1..1, the system font's own stops).
    public static func ctWeight(_ weight: Int32) -> CGFloat {
        let table: [(Int32, CGFloat)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        let w = max(100, min(900, weight))
        for i in 1..<table.count where w <= table[i].0 {
            let (w0, t0) = table[i - 1], (w1, t1) = table[i]
            return t0 + (t1 - t0) * CGFloat(w - w0) / CGFloat(w1 - w0)
        }
        return table.last!.1
    }

    /// The standalone resolution: the named family when it is installed, a generic family's platform
    /// font, the system font otherwise; weight and italic as traits.
    public static func resolve(_ f: FontData) -> CTFont {
        let size = CGFloat(max(0, f.size))
        var traits: [CFString: Any] = [kCTFontWeightTrait: ctWeight(f.weight)]
        if f.italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue }
        let family = f.family.trimmingCharacters(in: .whitespaces)
        var name: String? = family
        if let g = generic[family.lowercased()] { name = g }
        if let n = name, !n.isEmpty {
            let attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: n, kCTFontTraitsAttribute: traits]
            let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
            // Only an installed family: CoreText would otherwise hand back Helvetica for any name.
            if CTFontDescriptorCreateMatchingFontDescriptor(desc, Set([kCTFontFamilyNameAttribute as String]) as NSSet as CFSet) != nil {
                return CTFontCreateWithFontDescriptor(desc, size, nil)
            }
        }
        let system = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateCopyWithAttributes(system, size, nil, desc)
    }
}

/// One shaped line of text: what FILL_TEXT / STROKE_TEXT draw and `measureText` measures.
public struct TextLine {
    public let line: CTLine
    /// The advance width, letterSpacing px after every glyph (CSS / Canvas2D).
    public let width: CGFloat
    /// The font's ascent and descent, both positive.
    public let ascent: CGFloat
    public let descent: CGFloat

    public init(_ text: String, font: CTFont, letterSpacing: CGFloat = 0) {
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            // The context's fill / stroke color paints the glyphs (the painter sets it per command).
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if letterSpacing != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = letterSpacing }
        let str = NSAttributedString(string: text, attributes: attrs)
        line = CTLineCreateWithAttributedString(str)
        width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
    }

    /// The x of the line's left edge for a Canvas2D alignment at `x` (start / end read as left / right).
    public static func alignedX(_ x: CGFloat, width: CGFloat, align: TextAlign) -> CGFloat {
        switch align {
        case .center: return x - width / 2
        case .right, .end: return x - width
        case .left, .start: return x
        }
    }

    /// The baseline y for a Canvas2D textBaseline at `y` (the same table as the tgfx and Android painters).
    public static func baselineY(_ y: CGFloat, ascent: CGFloat, descent: CGFloat, baseline: TextBaseline) -> CGFloat {
        switch baseline {
        case .top: return y + ascent
        case .middle: return y + (ascent - descent) / 2
        case .bottom, .ideographic: return y - descent
        case .hanging: return y + ascent * 0.8
        case .alphabetic: return y
        }
    }
}
