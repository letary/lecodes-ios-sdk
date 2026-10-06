// The scene half of the C face (lecodes-core.h): what the 3D view, the textures, the AR controller
// and creator-2d's Metal arm call — the twin of core-jni.cpp's 3D / AR / creator-2d natives. Every
// call on the JS (= main) thread; each is an inline no-op in a variant without the engine behind it.
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
    /// A texture the host streams frames into (a video output, the AR camera); 0 without the engine.
    static func createExternalTexture() -> UInt32 { lc_createExternalTexture() }
    static func updateTexture(_ textureId: UInt32, pixelBuffer: CVPixelBuffer) {
        lc_updateTextureFromPixelBuffer(textureId, Unmanaged.passUnretained(pixelBuffer).toOpaque())
    }

    // MARK: - AR (the ARKit controller's engine calls)

    /// An instance of a BUILT-IN material by name ("camera") — `_creator.builtinMaterial`'s answer: the
    /// runtime finds the shader in the materials archive. nil = no engine, or no such material.
    static func builtinMaterial(_ name: String) -> UInt32? {
        let id = lc_builtinMaterial(name)
        return id == UInt32.max ? nil : id
    }
    static func setUniformTexture(_ materialInstanceId: UInt32, _ uniform: String, texture: UInt32) {
        lc_setUniformTexture(materialInstanceId, uniform, texture)
    }
    static func setUniformArray(_ materialInstanceId: UInt32, _ uniform: String, _ values: [Float]) {
        values.withUnsafeBufferPointer { lc_setUniformArray(materialInstanceId, uniform, $0.baseAddress, $0.count) }
    }
    /// The camera plane of the scene, drawn with the material (which becomes the scene's material).
    static func createARPlane(sceneId: UInt32, materialInstanceId: UInt32) { lc_createARPlane(sceneId, materialInstanceId) }
    /// The camera intrinsics rotated for the display into the scene's projection + the plane's uniforms.
    static func updateProjectionMatrixAR(sceneId: UInt32, fx: Float, fy: Float, cameraWidth: Float, cameraHeight: Float, displayAngle: Int32) {
        lc_updateProjectionMatrixAR(sceneId, fx, fy, cameraWidth, cameraHeight, displayAngle)
    }
    /// An anchor entity began / lost tracking: its visibility + the SDK's onTrackStateChange.
    static func updateTrackingState(entityId: UInt32, tracking: Bool) { lc_updateTrackingState(entityId, tracking) }
    /// An entity's world matrix (column-major, simd's layout).
    static func setMatrix(entityId: UInt32, _ m: simd_float4x4) {
        var m = m
        withUnsafePointer(to: &m) { p in
            p.withMemoryRebound(to: Float.self, capacity: 16) { lc_setMatrix(entityId, $0) }
        }
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
