// The scene half of the C face (lecodes-core.h): what the 3D view, the textures, the gl facade (LeCodes'
// GL — what a plugin's half drives the engine through) and creator-2d's Metal arm call — the twin of
// core-jni.cpp's 3D / creator-2d natives. Every call on the JS (= main) thread; each is a no-op in a
// variant without the engine behind it.
import CLeCodesCore
import CoreVideo
import Foundation
import Metal
import simd

/// The one MTLDevice of the process: Filament makes its own (`init()`), creator-2d and the scene
/// views take this one — on an iPhone every MTLCreateSystemDefaultDevice() is the same GPU (the
/// desktop host checks the two against each other; here there is one).
public enum MetalDevice {
    public static let shared: MTLDevice? = MTLCreateSystemDefaultDevice()
}

public extension Core {

    // MARK: - The 3D view

    /// Device px per logical point of the scene view: touches arrive in points, the viewport is px.
    static func setDensityGL(x: Float, y: Float) { lc_setDensityGL(x, y) }

    // MARK: - Textures

    static func isKtx2(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in lc_isKtx2(raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count) }
    }
    /// nil = the engine could not transcode it.
    static func createTextureFromKtx2(_ data: Data, flags: UInt32) -> UInt32? {
        let id = data.withUnsafeBytes { raw in lc_createTextureFromKtx2(raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, flags) }
        return id == UInt32.max ? nil : id
    }
    /// A malloc'd straight-alpha RGBA8 bitmap the engine TAKES (top row first, `stride` bytes per
    /// row; freed after the upload, also on failure). nil = failure.
    static func createTextureFromBitmap(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int, flags: UInt32) -> UInt32? {
        let id = lc_createTextureFromBitmap(pixels, UInt32(width), UInt32(height), UInt32(stride), flags)
        return id == UInt32.max ? nil : id
    }
    static func textureSize(_ textureId: UInt32) -> (width: Int, height: Int) {
        (Int(lc_textureWidth(textureId)), Int(lc_textureHeight(textureId)))
    }
    /// A texture the host streams frames into (a video output, a camera); nil without the engine.
    static func createExternalTexture() -> UInt32? {
        let id = lc_createExternalTexture()
        return id == UInt32.max ? nil : id
    }
    static func updateTexture(_ textureId: UInt32, pixelBuffer: CVPixelBuffer) {
        lc_updateTextureFromPixelBuffer(textureId, Unmanaged.passUnretained(pixelBuffer).toOpaque())
    }
    /// Free a texture the host made: at once when nothing samples it, else when the last user lets go.
    static func destroyTexture(_ textureId: UInt32) { lc_destroyTexture(textureId) }

    // MARK: - The gl facade's engine calls (LeCodes' GL)

    /// The entity is alive in the engine (the app may have destroyed one it handed a plugin).
    static func entityExists(_ entityId: UInt32) -> Bool { lc_entityExists(entityId) }
    /// An entity's WORLD matrix (column-major, simd's layout); skipped for a dead entity.
    static func setMatrix(entityId: UInt32, _ m: simd_float4x4) {
        withFloats(m) { lc_setMatrix(entityId, $0) }
    }
    static func setVisible(entityId: UInt32, _ visible: Bool) { lc_setVisible(entityId, visible) }
    /// The pose of the scene's camera (its world matrix).
    static func setCameraMatrix(sceneId: UInt32, _ m: simd_float4x4) {
        withFloats(m) { lc_setCameraMatrix(sceneId, $0) }
    }
    /// A projection the host computes (OpenGL clip conventions) in place of the scene's fov one.
    static func setCameraProjectionMatrix(sceneId: UInt32, _ m: simd_float4x4, near: Float, far: Float) {
        withFloats(m) { lc_setCameraProjectionMatrix(sceneId, $0, near, far) }
    }
    static func clearCameraProjectionMatrix(sceneId: UInt32) { lc_clearCameraProjectionMatrix(sceneId) }
    /// The scene's background: the texture through the affine map `uv` (6 floats, row-major
    /// [a b tx  c d ty]); nil = none.
    static func setSceneBackground(sceneId: UInt32, texture: UInt32?, uv: [Float]) {
        guard uv.count == 6 else { return }
        uv.withUnsafeBufferPointer { lc_setSceneBackground(sceneId, texture ?? UInt32.max, $0.baseAddress) }
    }
    /// The scene view's size in points — the scene's viewport over the density of setDensityGL, the
    /// space its touches arrive in; 0 × 0 before the scene was first shown.
    static func sceneViewport(sceneId: UInt32) -> (width: Float, height: Float) {
        var size = SIMD2<Float>(0, 0)
        withUnsafeMutablePointer(to: &size) { p in p.withMemoryRebound(to: Float.self, capacity: 2) { lc_sceneViewport(sceneId, $0) } }
        return (size.x, size.y)
    }
    /// The composite of the scene's next frame: RGBA8, top row first — nil (0 × 0) when refused.
    /// `done` once, on the main thread.
    static func readPixels(sceneId: UInt32, _ done: @escaping (Data?, Int, Int) -> Void) {
        let box = Unmanaged.passRetained(PixelsDone(done)).toOpaque()
        lc_readPixels(sceneId, { user, rgba, width, height in
            guard let user else { return }
            let box = Unmanaged<PixelsDone>.fromOpaque(user).takeRetainedValue()
            if let rgba, width > 0, height > 0 {
                box.done(Data(bytes: rgba, count: Int(width) * Int(height) * 4), Int(width), Int(height))
            } else {
                box.done(nil, 0, 0)
            }
        }, box)
    }

    private static func withFloats(_ m: simd_float4x4, _ body: (UnsafePointer<Float>) -> Void) {
        var m = m
        withUnsafePointer(to: &m) { p in p.withMemoryRebound(to: Float.self, capacity: 16) { body($0) } }
    }

    // MARK: - creator-2d's Metal arm

    /// sokol on the device (HostScene2d.init2D), once per process.
    static func scene2dInitMetal(device: MTLDevice) { lc_2dInitMetal(Unmanaged.passUnretained(device).toOpaque()) }
    /// The presented scene's drawable size (device px) and density (device px per logical point).
    static func scene2dSetViewport(width: Int, height: Int) { lc_2dSetViewport(Int32(width), Int32(height)) }
    static func scene2dSetDensity(_ density: Float) { lc_2dSetDensity(density) }
    /// An offscreen target over a host-owned RGBA8 render-target texture; 0 = failure (no engine).
    static func scene2dTargetCreateMetal(width: Int, height: Int, texture: MTLTexture) -> Int32 {
        lc_2dTargetCreateMetal(Int32(width), Int32(height), Unmanaged.passUnretained(texture).toOpaque())
    }
    static func scene2dTargetDestroy(_ targetId: Int32) { lc_2dTargetDestroy(targetId) }
    /// scene2dRenderFrame draws the presented scene here (0 = none).
    static func scene2dSetPresentTarget(_ targetId: Int32) { lc_2dSetPresentTarget(targetId) }
    /// One scene, no simulation, into a target — an image node's picture.
    static func scene2dDrawSceneTarget(sceneId: Int32, targetId: Int32, density: Float) { lc_2dDrawSceneTarget(sceneId, targetId, density) }
}

/// The closure a readPixels completes, boxed for the C callback's `user`.
private final class PixelsDone {
    let done: (Data?, Int, Int) -> Void
    init(_ done: @escaping (Data?, Int, Int) -> Void) { self.done = done }
}
