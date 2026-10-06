// A bitmap surface for the painter: a CGBitmapContext in the painter's sRGB space whose BASE
// transform is the y-flip, so a y-down draw list lands top-down, and its pixels back as straight
// RGBA8 (what a host's readPixels / the core's ac_encode want). The tests paint into these; a host
// keeps one per surface id.
import Accelerate
import CoreGraphics
import Foundation

public enum Surface {
    /// A transparent pw × ph premultiplied-RGBA8 context, y-down (the flip is its base CTM).
    public static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: Painter.colorSpace, bitmapInfo: info) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    /// Clears the whole surface to transparent black, whatever the CTM.
    public static func clear(_ ctx: CGContext) {
        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted())
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.restoreGState()
    }

    /// The context's pixels as straight (non-premultiplied) RGBA8, top row first.
    public static func straightRGBA(_ ctx: CGContext) -> [UInt8] {
        let w = ctx.width, h = ctx.height, stride = ctx.bytesPerRow
        guard let data = ctx.data, w > 0, h > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { dst in
            var src = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride)
            var dstBuf = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            _ = vImageUnpremultiplyData_RGBA8888(&src, &dstBuf, vImage_Flags(kvImageNoFlags))
        }
        return out
    }

    /// One pixel as straight RGBA8 (top-left origin).
    public static func pixel(_ ctx: CGContext, _ x: Int, _ y: Int) -> [UInt8] {
        guard let data = ctx.data, x >= 0, y >= 0, x < ctx.width, y < ctx.height else { return [0, 0, 0, 0] }
        let p = data.advanced(by: y * ctx.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        let a = Int(p[3])
        if a == 0 { return [0, 0, 0, 0] }
        if a == 255 { return [p[0], p[1], p[2], 255] }
        let un = { (c: UInt8) -> UInt8 in UInt8(min(255, (Int(c) * 255 + a / 2) / a)) }
        return [un(p[0]), un(p[1]), un(p[2]), UInt8(a)]
    }

    /// A CGImage of the context's current pixels (copy-on-write: free until the context is drawn to again).
    public static func image(_ ctx: CGContext) -> CGImage? { ctx.makeImage() }
}
