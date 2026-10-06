// The `gl` table (gl.d.ts) of the rendered host — the twin of hosts/android's GLHost.kt: the scene
// view's lifetime hooks (the swap chain is the view's, LeCodesView mounts it as the presented
// surface), the textures the platform decodes (ImageIO → the engine's bitmap upload; KTX2 through
// the engine's own transcoder), a media player's frames as a texture, and AR over the registered
// controller kinds. Filament creates its own Metal engine (`init()`): no getGLContext here, and
// nothing to re-bind on engineCreated but a mounted scene view's swap chain. HeadlessGL is the
// engine-only twin (no swap chain to present, no textures).
import Foundation
import LeCodesCore

final class GLHost: HostGL {
    weak var engine: LeCodesEngine?

    /// The scene is presented (the legacy first open) — a re-created root view brings it back.
    private(set) var isSceneOpen = false

    /// The swap chain died with the rebuilt engine: a mounted scene view makes a new one. So did
    /// the scene / texture ids an AR session from before writes to every camera frame.
    var engineCreated: (() -> Void)? {
        { [weak self] in
            self?.resetAR()
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

    /// A media player's frames as an engine texture (an external texture the players pump every
    /// frame); 0 = no such player / no engine.
    var createMediaPlayerTexture: ((Int32) -> Int32)? {
        { [weak self] playerId in Int32(truncatingIfNeeded: self?.engine?.media.players.createTexture(playerId) ?? 0) }
    }

    // MARK: - AR

    /// The controller kinds the embedder registered (LeCodesEngine.registerARController), by mode.
    var controllerFactories: [String: () -> ARController] = [:]
    /// One controller per scene that asked for one (createARController), started by launchAR.
    private var controllers: [UInt32: ARController] = [:]
    /// The running session, if any.
    private(set) var arController: ARController?

    var createARController: ((UInt32, UInt32, String) -> Void)? {
        { [weak self] sceneId, cameraId, mode in
            guard let self else { return }
            guard let factory = controllerFactories[mode] else {
                print("[ar] ARController '\(mode)' is not registered (LeCodesEngine.registerARController)")
                return
            }
            let controller = factory()
            controller.sceneId = sceneId
            controller.cameraEntityId = cameraId
            controllers[sceneId] = controller
        }
    }
    var createRootAnchor: ((UInt32, UInt32) -> Void)? {
        { [weak self] sceneId, entityId in self?.controllers[sceneId]?.createRootAnchor(entityId) }
    }
    var createAnchor: ((UInt32, UInt32, Float, Int32) -> Void)? {
        { [weak self] sceneId, entityId, physicalWidth, systemId in
            guard let data = Buffers.get(systemId) else { print("[ar] createAnchor: no buffer \(systemId)"); return }
            self?.controllers[sceneId]?.createAnchor(entityId, data, physicalWidth)
        }
    }
    var launchAR: ((UInt32, JSCallback, JSCallback) -> Void)? {
        { [weak self] sceneId, onComplete, onReject in
            guard let self, let controller = controllers[sceneId] else {
                Core.reject(onComplete, reject: onReject, message: "ARController for scene \(sceneId) is not created")
                return
            }
            arController?.stop()
            arController = controller
            controller.start({ Core.resolve(onComplete, reject: onReject) },
                             { message in Core.reject(onComplete, reject: onReject, message: message) })
        }
    }
    var stopAR: (() -> Void)? {
        { [weak self] in
            self?.arController?.stop()
            self?.arController = nil
        }
    }

    /// The running session ends, the controllers go: at a world swap (an AR scene left by
    /// Router.pop or by the swap keeps the session running, writing into the next world's engine),
    /// at an engine rebuild, at teardown.
    func resetAR() {
        arController?.stop()
        arController = nil
        controllers.removeAll()
    }
}
