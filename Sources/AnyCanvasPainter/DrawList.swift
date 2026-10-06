// The draw list in Swift: the typed commands and the reader of the word buffer (spec/draw.h). The
// twin of painters/android/.../DrawList.kt and painters/web/src/drawlist.ts — the tests hold it
// against the core's JSON dump on every golden. Colors are RGBA floats as on the wire.
import Foundation
import AnyCanvasSpec

/// A draw list as the core produced it: f32 words + the string table.
public struct DrawList {
    public var words: [Float]
    public var strings: [String]

    public init(words: [Float], strings: [String]) {
        self.words = words
        self.strings = strings
    }

    /// Decode into commands. A command this build does not know is skipped by its length.
    public func commands() throws -> [DrawCommand] { var r = DrawReader(self); return try r.readAll() }

    /// The binary file acdump / the golden test write: u32 wordCount, f32 words, u32 stringCount,
    /// (u32 byteLen, utf8)*. Little-endian.
    public init(binary data: Data) throws {
        var pos = 0
        func u32() throws -> Int {
            guard pos + 4 <= data.count else { throw DrawListError.truncated(at: pos) }
            let v = data.subdata(in: pos..<pos + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            pos += 4
            return Int(UInt32(littleEndian: v))
        }
        let wordCount = try u32()
        guard pos + wordCount * 4 <= data.count else { throw DrawListError.truncated(at: pos) }
        var words = [Float](repeating: 0, count: wordCount)
        data.subdata(in: pos..<pos + wordCount * 4).withUnsafeBytes { raw in
            for i in 0..<wordCount { words[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))) }
        }
        pos += wordCount * 4
        let stringCount = try u32()
        var strings: [String] = []
        strings.reserveCapacity(stringCount)
        for _ in 0..<stringCount {
            let len = try u32()
            guard pos + len <= data.count else { throw DrawListError.truncated(at: pos) }
            strings.append(String(decoding: data.subdata(in: pos..<pos + len), as: UTF8.self))
            pos += len
        }
        self.init(words: words, strings: strings)
    }
}

public enum DrawListError: Error, Equatable {
    case truncated(at: Int)
    case badStringIndex(Int)
    case badPathVerb(Int)
    case overrun(command: Int32, at: Int)
}

/// A 2D affine transform, Canvas2D / SVG layout: x' = a*x + c*y + e, y' = b*x + d*y + f.
public struct Matrix: Equatable {
    public var a: Float, b: Float, c: Float, d: Float, e: Float, f: Float
    public init(a: Float, b: Float, c: Float, d: Float, e: Float, f: Float) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }
    public static let identity = Matrix(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)
    /// The six values in wire order.
    public var values: [Float] { [a, b, c, d, e, f] }
}

/// Straight (non-premultiplied) RGBA, 0..1.
public struct Color: Equatable {
    public var r: Float, g: Float, b: Float, a: Float
    public init(r: Float, g: Float, b: Float, a: Float) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var values: [Float] { [r, g, b, a] }
}

public struct Stop: Equatable {
    public var offset: Float
    public var color: Color
    public init(offset: Float, color: Color) { self.offset = offset; self.color = color }
}

public enum PaintData: Equatable {
    case solid(alpha: Float, color: Color)
    /// `matrix` = gradient space → user space; the axis runs (0,0) → (1,0).
    case linear(alpha: Float, matrix: Matrix, spread: Spread, stops: [Stop])
    /// The unit end circle at the origin of gradient space; the start circle at (fx, fy), radius r0.
    case radial(alpha: Float, matrix: Matrix, fx: Float, fy: Float, r0: Float, spread: Spread, stops: [Stop])

    public var alpha: Float {
        switch self {
        case .solid(let alpha, _), .linear(let alpha, _, _, _), .radial(let alpha, _, _, _, _, _, _): return alpha
        }
    }
}

public struct StrokeData: Equatable {
    public var width: Float
    public var join: LineJoin
    public var cap: LineCap
    public var miterLimit: Float
    public var dashOffset: Float
    public var dash: [Float]
    public init(width: Float, join: LineJoin, cap: LineCap, miterLimit: Float, dashOffset: Float, dash: [Float]) {
        self.width = width; self.join = join; self.cap = cap; self.miterLimit = miterLimit; self.dashOffset = dashOffset; self.dash = dash
    }
}

public struct FontData: Equatable {
    public var family: String
    public var size: Float
    public var weight: Int32
    public var italic: Bool
    public init(family: String, size: Float, weight: Int32, italic: Bool) {
        self.family = family; self.size = size; self.weight = weight; self.italic = italic
    }
}

/// A path: the verb words of the wire format (PathVerb + coordinates), decoded by the painter.
public struct PathData: Equatable {
    public var words: [Float]
    public init(words: [Float]) { self.words = words }
}

/// One line of text: what FILL_TEXT and STROKE_TEXT share.
public struct TextData: Equatable {
    public var text: String
    public var x: Float, y: Float
    public var maxWidth: Float
    public var font: FontData
    public var align: TextAlign
    public var baseline: TextBaseline
    public var letterSpacing: Float
    public init(text: String, x: Float, y: Float, maxWidth: Float, font: FontData, align: TextAlign, baseline: TextBaseline, letterSpacing: Float) {
        self.text = text; self.x = x; self.y = y; self.maxWidth = maxWidth; self.font = font
        self.align = align; self.baseline = baseline; self.letterSpacing = letterSpacing
    }
}

/// x y w h.
public struct Rect4: Equatable {
    public var x: Float, y: Float, w: Float, h: Float
    public init(x: Float, y: Float, w: Float, h: Float) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var values: [Float] { [x, y, w, h] }
}

public enum DrawCommand: Equatable {
    case setTransform(Matrix)
    case save
    case restore
    case clip(rule: FillRule, path: PathData)
    case fillPath(rule: FillRule, paint: PaintData, path: PathData)
    case strokePath(stroke: StrokeData, paint: PaintData, path: PathData)
    case fillText(TextData, paint: PaintData)
    case strokeText(TextData, stroke: StrokeData, paint: PaintData)
    /// src in the surface's device px, dst in user space.
    case drawImage(surface: Int32, src: Rect4, dst: Rect4, alpha: Float)
    case clearRect(Rect4)
}

/// Walks a draw list.
public struct DrawReader {
    private let list: DrawList
    private var pos = 0

    public init(_ list: DrawList) { self.list = list }

    private mutating func f() throws -> Float {
        guard pos < list.words.count else { throw DrawListError.truncated(at: pos) }
        let v = list.words[pos]
        pos += 1
        return v
    }
    private mutating func i() throws -> Int32 { Int32(try f()) }
    private mutating func str() throws -> String {
        let k = Int(try i())
        guard k >= 0, k < list.strings.count else { throw DrawListError.badStringIndex(k) }
        return list.strings[k]
    }
    private mutating func color() throws -> Color { Color(r: try f(), g: try f(), b: try f(), a: try f()) }
    private mutating func matrix() throws -> Matrix { Matrix(a: try f(), b: try f(), c: try f(), d: try f(), e: try f(), f: try f()) }
    private mutating func rect() throws -> Rect4 { Rect4(x: try f(), y: try f(), w: try f(), h: try f()) }

    private mutating func paint() throws -> PaintData {
        let kind = try i()
        let alpha = try f()
        if kind == Paint.color.rawValue { return .solid(alpha: alpha, color: try color()) }
        let m = try matrix()
        var fx: Float = 0, fy: Float = 0, r0: Float = 0
        if kind == Paint.radial.rawValue { fx = try f(); fy = try f(); r0 = try f() }
        let spread = Spread(rawValue: try i()) ?? .pad
        let n = Int(try i())
        var stops: [Stop] = []
        stops.reserveCapacity(max(n, 0))
        for _ in 0..<max(n, 0) { stops.append(Stop(offset: try f(), color: try color())) }
        return kind == Paint.radial.rawValue
            ? .radial(alpha: alpha, matrix: m, fx: fx, fy: fy, r0: r0, spread: spread, stops: stops)
            : .linear(alpha: alpha, matrix: m, spread: spread, stops: stops)
    }

    private mutating func stroke() throws -> StrokeData {
        let width = try f()
        let join = LineJoin(rawValue: try i()) ?? .miter
        let cap = LineCap(rawValue: try i()) ?? .butt
        let miter = try f(), offset = try f()
        let n = Int(try i())
        var dash: [Float] = []
        for _ in 0..<max(n, 0) { dash.append(try f()) }
        return StrokeData(width: width, join: join, cap: cap, miterLimit: miter, dashOffset: offset, dash: dash)
    }

    private mutating func font() throws -> FontData { FontData(family: try str(), size: try f(), weight: try i(), italic: try i() != 0) }

    private mutating func path() throws -> PathData {
        let n = Int(try i())
        guard n >= 0, pos + n <= list.words.count else { throw DrawListError.truncated(at: pos) }
        let words = Array(list.words[pos..<pos + n])
        pos += n
        return PathData(words: words)
    }

    private mutating func text() throws -> TextData {
        let t = try str(), x = try f(), y = try f(), mw = try f()
        let font = try font()
        let align = TextAlign(rawValue: try i()) ?? .start
        let baseline = TextBaseline(rawValue: try i()) ?? .alphabetic
        let ls = try f()
        return TextData(text: t, x: x, y: y, maxWidth: mw, font: font, align: align, baseline: baseline, letterSpacing: ls)
    }

    public mutating func readAll() throws -> [DrawCommand] {
        var out: [DrawCommand] = []
        let w = list.words
        while pos + 2 <= w.count {
            let id = try i()
            let len = Int(try i())
            let end = pos + len
            guard len >= 0, end <= w.count else { throw DrawListError.truncated(at: pos) }
            switch DrawCmd(rawValue: id) {
            case .setTransform: out.append(.setTransform(try matrix()))
            case .save: out.append(.save)
            case .restore: out.append(.restore)
            case .clip: out.append(.clip(rule: FillRule(rawValue: try i()) ?? .nonzero, path: try path()))
            case .fillPath:
                let rule = FillRule(rawValue: try i()) ?? .nonzero
                let p = try paint()
                out.append(.fillPath(rule: rule, paint: p, path: try path()))
            case .strokePath:
                let s = try stroke()
                let p = try paint()
                out.append(.strokePath(stroke: s, paint: p, path: try path()))
            case .fillText:
                let t = try text()
                out.append(.fillText(t, paint: try paint()))
            case .strokeText:
                let t = try text()
                let s = try stroke()
                out.append(.strokeText(t, stroke: s, paint: try paint()))
            case .drawImage:
                let surface = try i()
                let src = try rect(), dst = try rect()
                out.append(.drawImage(surface: surface, src: src, dst: dst, alpha: try f()))
            case .clearRect: out.append(.clearRect(try rect()))
            case nil: break   // unknown: skipped by its length
            }
            if pos > end { throw DrawListError.overrun(command: id, at: pos) }
            pos = end
        }
        return out
    }
}

/// The path verbs of a PathData, decoded (what the tests compare against the JSON dump; the painter
/// walks the words directly).
public enum PathSegment: Equatable {
    case move(Float, Float)
    case line(Float, Float)
    case quad(Float, Float, Float, Float)
    case cubic(Float, Float, Float, Float, Float, Float)
    case close
}

extension PathData {
    public func segments() throws -> [PathSegment] {
        var out: [PathSegment] = []
        var i = 0
        let w = words
        func need(_ n: Int) throws { if i + n > w.count { throw DrawListError.truncated(at: i) } }
        while i < w.count {
            let verb = Int32(w[i]); i += 1
            switch PathVerb(rawValue: verb) {
            case .move: try need(2); out.append(.move(w[i], w[i + 1])); i += 2
            case .line: try need(2); out.append(.line(w[i], w[i + 1])); i += 2
            case .quad: try need(4); out.append(.quad(w[i], w[i + 1], w[i + 2], w[i + 3])); i += 4
            case .cubic: try need(6); out.append(.cubic(w[i], w[i + 1], w[i + 2], w[i + 3], w[i + 4], w[i + 5])); i += 6
            case .close: out.append(.close)
            case nil: throw DrawListError.badPathVerb(Int(verb))
            }
        }
        return out
    }
}
