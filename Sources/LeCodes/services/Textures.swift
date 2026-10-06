// Encoded image bytes → the straight-alpha RGBA8 bitmap the engine's createTextureFromBitmap takes
// (the old host's Texture.swift, minus the Metal texture: the engine uploads and mips itself). Two
// contracts, both what the web host establishes with `texStorage2D(..., SRGB8_ALPHA8)` +
// `UNPACK_PREMULTIPLY_ALPHA_WEBGL = false`:
//  1. STRAIGHT (non-premultiplied) alpha — shaders premultiply themselves (particles.mat ends on
//     `float4(rgb * alpha, …)`), so premultiplied texels multiply twice and every soft edge darkens
//     toward black (a grey rim around smoke / glow sprites). CGBitmapContext cannot draw straight
//     RGBA8 at all: draw premultiplied, undo it with vImage.
//  2. sRGB-ENCODED bytes (the engine types the texture sRGB unless the linear flag says otherwise,
//     and the GPU linearizes on sampling): converting on the CPU into 8 bits bands the dark end.
// The decode runs off the main thread (a screen's worth of images in parallel); the engine call
// stays on the JS thread (the caller's).
import Accelerate
import CoreGraphics
import Foundation
import ImageIO

enum TextureDecoder {
    struct Bitmap {
        /// malloc'd, `stride` × `height` bytes, the engine takes it.
        let pixels: UnsafeMutablePointer<UInt8>
        let width: Int
        let height: Int
        let stride: Int
        func free() { Foundation.free(pixels) }
    }

    /// nil = not an image ImageIO decodes (or empty).
    static func decode(_ data: Data) -> Bitmap? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let stride = width * 4
        guard let pixels = malloc(stride * height)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // sRGB, not linearSRGB: the engine types the texture sRGB, the sampler linearizes on read.
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride, space: space, bitmapInfo: info) else {
            free(pixels)
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Premultiplied → straight, in place. Fully transparent texels have no recoverable colour, so
        // vImage leaves them at zero — harmless, alpha 0 contributes nothing either way.
        var buffer = vImage_Buffer(data: pixels, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
        vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        return Bitmap(pixels: pixels, width: width, height: height, stride: stride)
    }
}
