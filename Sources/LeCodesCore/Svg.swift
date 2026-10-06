// The SVG front end of the ONE AnyCanvas core the runtime links — the xcframework's CAnyCanvas
// module (build-apple.sh writes its module map; the archive carries the core, so the host never
// links the AnyCanvas package's own `AnyCanvas` product: a second core = duplicate symbols). The
// twin of the library's AnyCanvas.swift binding, cut to what the image nodes need: parse markup,
// its natural size, the draw list aspect-fitted into a box (with an optional tint), the sniffing
// of encoded bytes. A draw list the core returns is owned by the context until the next call, so
// every method copies it into Swift arrays before returning. Main thread only.
import CAnyCanvas
import Foundation

public final class SvgDocument {
    /// The core's context for the SVG draws (its scratch draw list lives in it), one per process.
    private static let context: OpaquePointer? = ac_context_create()

    private var handle: OpaquePointer?
    /// The document's natural size, logical px.
    public let width: Float
    public let height: Float

    /// Parses `markup`; nil when the core rejects it or the document has no size.
    public init?(markup: String) {
        var bytes = Array(markup.utf8)
        guard !bytes.isEmpty else { return nil }
        let h = bytes.withUnsafeMutableBufferPointer { buf -> OpaquePointer? in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { ac_svg_parse($0, buf.count) }
        }
        guard let h else { return nil }
        handle = h
        var w: Float = 0, hh: Float = 0
        ac_svg_size(h, &w, &hh)
        width = w
        height = hh
        guard w > 0, hh > 0 else { ac_svg_free(h); handle = nil; return nil }
    }
    deinit { if let h = handle { ac_svg_free(h) } }

    /// The draw list aspect-fitted into `width` × `height` device px (0 × 0: the natural size);
    /// `tint` (0xRRGGBBAA) replaces every color. The painter of renderers/uikit replays it.
    public func draw(width w: Float = 0, height h: Float = 0, tint: UInt32? = nil) -> (words: [Float], strings: [String]) {
        guard let handle, let ctx = SvgDocument.context else { return ([], []) }
        var list = ac_drawlist()
        if let t = tint {
            let rgba: [Float] = [Float((t >> 24) & 0xFF) / 255, Float((t >> 16) & 0xFF) / 255, Float((t >> 8) & 0xFF) / 255, Float(t & 0xFF) / 255]
            rgba.withUnsafeBufferPointer { ac_svg_draw(ctx, handle, w, h, 1, $0.baseAddress, &list) }
        } else {
            ac_svg_draw(ctx, handle, w, h, 0, nil, &list)
        }
        let words = list.wordCount > 0 && list.words != nil ? Array(UnsafeBufferPointer(start: list.words, count: Int(list.wordCount))) : []
        var strings: [String] = []
        if list.stringCount > 0, let s = list.strings {
            strings.reserveCapacity(Int(list.stringCount))
            for i in 0..<Int(list.stringCount) { strings.append(s[i].map { String(cString: $0) } ?? "") }
        }
        return (words, strings)
    }

    /// True if the bytes look like an SVG document (the core's sniffing, the same the runtime does
    /// for canvas images).
    public static func looksLikeSvg(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in ac_looks_like_svg(raw.baseAddress, raw.count) != 0 }
    }
}
