// The `gl` table (gl.d.ts) of the rendered host — the twin of hosts/android's GLHost.kt: the scene
// view's lifetime hooks (the swap chain is the view's, LeCodesView mounts it as the presented
// surface), the textures the platform decodes (ImageIO → the engine's bitmap upload; KTX2 through
// the engine's own transcoder), a media player's frames as a texture. Filament creates its own
// Metal engine (`init()`): no getGLContext here, and nothing to re-bind on engineCreated but a
// mounted scene view's swap chain. AR is not here: it is a plugin, over the gl facade (scene/GL.swift).
// HeadlessGL is the engine-only twin (no swap chain to present, no textures).
import Foundation
import LeCodesCore

final class GLHost: HostGL {
    weak var engine: LeCodesEngine?

    /// The scene is presented (the legacy first open) — a re-created root view brings it back.
    private(set) var isSceneOpen = false

    /// The swap chain died with the rebuilt engine: a mounted scene view makes a new one. So did
    /// the textures the gl facade handed out (their ids restart in the new engine).
    var engineCreated: (() -> Void)? {
        { [weak self] in
            self?.engine?.gl.engineRebuilt()
            self?.engine?.rootView?.sceneView?.createSwapChain()
        }
    }
    /// The legacy first scene.open(): the scene view exists and is the presented surface from now.
    var createGLView: (() -> Void)? {
        { [weak self] in
            self?.isSceneOpen = true
            self?.engine?.rootView?.ensureSceneView()
        }
    }
    /// The scene closed for good: the view goes (deferred under a transition about to play over it).
    var closeScene: (() -> Void)? {
        { [weak self] in
            self?.isSceneOpen = false
            self?.engine?.rootView?.sceneClosed()
        }
    }

    // MARK: - textures

    /// Host buffer `systemId` → an engine texture: KTX2 through the engine (synchronous: it transcodes
    /// on the JS thread, the bytes may go right after), anything else decoded off the main thread
    /// and uploaded ON it — the engine call must never race a frame. `flags` = Texture.load's options.
    func createTexture(systemId: Int32, flags: UInt32, onComplete: JSCallback, onReject: JSCallback) {
        guard let data = Buffers.get(systemId) else {
            Core.reject(onComplete, reject: onReject, message: "Buffer with id \(systemId) not found")
            return
        }
        if Core.isKtx2(data) {
            guard let id = Core.createTextureFromKtx2(data, flags: flags) else {
                Core.reject(onComplete, reject: onReject, message: "Failed to transcode KTX2 texture")
                return
            }
            let size = Core.textureSize(id)
            Core.resolve(onComplete, reject: onReject, [.double(Double(id)), .int(Int32(size.width)), .int(Int32(size.height))])
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bitmap = TextureDecoder.decode(data) else {
                Core.reject(onComplete, reject: onReject, message: "Failed to decode image data")
                return
            }
            DispatchQueue.main.async {
                guard let id = Core.createTextureFromBitmap(bitmap.pixels, width: bitmap.width, height: bitmap.height, stride: bitmap.stride, flags: flags) else {
                    Core.reject(onComplete, reject: onReject, message: "Failed to create texture")
                    return
                }
                Core.resolve(onComplete, reject: onReject, [.double(Double(id)), .int(Int32(bitmap.width)), .int(Int32(bitmap.height))])
            }
        }
    }

    /// A media player's frames as an engine texture (an external texture of the gl facade the
    /// players pump every frame); 0 = no such player / no engine.
    var createMediaPlayerTexture: ((Int32) -> Int32)? {
        { [weak self] playerId in Int32(truncatingIfNeeded: self?.engine?.media.players.createTexture(playerId) ?? 0) }
    }
}
