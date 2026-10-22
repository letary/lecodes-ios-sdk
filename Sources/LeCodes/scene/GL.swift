// The gl facade (`engine.gl`): what a plugin's native half drives the 3D engine through — scenes,
// entities, textures and the frame, never AR (docs/plans/ar-plugin-plan.md; the twins: hosts/android's
// GL.kt, the web hosts' `host.gl`). A half DRIVES what the app handed it (an `Entity`, a `Scene3D` of
// its contract) and never creates or frees an entity or a scene; the one thing it creates is an
// external texture, its session's, closed in `destroy`. Main thread only (the engine's thread here).
// Every call is a no-op — and createExternalTexture nil — on a host without the 3D engine (the `core`
// variant), the way Core's scene calls are.
import CoreVideo
import Foundation
import LeCodesCore
import simd
import UIKit

/// An entity of the 3D engine the app handed a plugin: `Entity` of a contract, a Node's `_h.id` on
/// the wire. An entity the app destroyed since is skipped by every call.
public struct Entity: Hashable {
    public let id: UInt32
    public init(_ id: UInt32) { self.id = id }
}

/// A 3D scene the app handed a plugin: `Scene3D` of a contract, a Scene's `_id` on the wire.
public struct Scene3D: Hashable {
    public let id: UInt32
    public init(_ id: UInt32) { self.id = id }
}

public extension WireIn {
    /// An `Entity` the app sent (a whole number in u32's range); nil when it is not one.
    var entity: Entity? { u32.map(Entity.init) }
    /// A `Scene3D` the app sent; nil when it is not one.
    var scene3D: Scene3D? { u32.map(Scene3D.init) }

    private var u32: UInt32? {
        guard let d = f64, d == d.rounded(), d >= 0, d <= Double(UInt32.max) else { return nil }
        return UInt32(d)
    }
}

public extension Entity {
    /// The entity as it crosses: its id, a number.
    func write(to out: WireOut) { out.f64(Double(id)) }
}

/// A texture whose frames the host streams in (a camera, a video): the engine samples the newest
/// pixel buffer it was handed. The session that made it closes it.
public final class ExternalTexture {
    /// The engine's id of the texture (what `setBackground` and a material sample).
    public let id: UInt32
    private let generation: Int
    private weak var gl: GL?
    private var closed = false

    init(id: UInt32, generation: Int, gl: GL) {
        self.id = id
        self.generation = generation
        self.gl = gl
    }

    /// The texture's engine is the current one and the texture is not closed.
    var isLive: Bool { !closed && gl?.generation == generation }

    /// The newest frame (ARKit's capturedImage, an AVPlayerItemVideoOutput's buffer).
    public func update(_ pixelBuffer: CVPixelBuffer) {
        guard isLive else { return }
        Core.updateTexture(id, pixelBuffer: pixelBuffer)
    }

    /// Done with it: the engine frees it once nothing samples it (a background showing it goes first).
    public func close() {
        guard isLive else { closed = true; return }
        closed = true
        gl?.textureClosed(self)
        Core.destroyTexture(id)
    }
}

public final class GL {
    /// Stops a frame body (`onFrame`).
    public typealias Cancel = () -> Void

    /// Where a scene is shown (`GL.viewport`): its view's size and how the display is turned. A half sizes
    /// its framework's display by it (a projection, a crop, a hit test) and reads it every frame — there is
    /// no change event.
    public struct Viewport: Equatable {
        /// Points: the space the scene's touches arrive in (what a half's hit test is handed). 0 × 0 before
        /// the scene is first shown — the frame after it is presented carries the size.
        public let width: CGFloat
        public let height: CGFloat
        /// The display's turn from the device's natural (portrait) orientation, degrees: 0, 90 (turned
        /// counter-clockwise: the interface's landscapeRight), 180, 270 (landscapeLeft) — Android's
        /// `display.rotation` × 90, the web's `screen.orientation.angle`.
        public let rotation: Int

        public init(width: CGFloat, height: CGFloat, rotation: Int) {
            self.width = width
            self.height = height
            self.rotation = rotation
        }
    }

    private let hasEngine: Bool
    /// Bumped when the engine is rebuilt (HostGL.engineCreated): texture ids restart there, so a
    /// texture of the old engine must never name one of the new.
    fileprivate(set) var generation = 0
    private var bodies: [(id: Int, body: () -> Void)] = []
    private var nextBody = 0
    /// The texture each scene shows as its background, so a closed texture takes its background along.
    private var backgrounds: [UInt32: ExternalTexture] = [:]
    /// The view the scenes are shown under (LeCodesEngine.rootView): its window scene's interface
    /// orientation is the viewport's rotation.
    weak var stage: UIView?

    init(hasEngine: Bool) { self.hasEngine = hasEngine }

    /// The entity's world matrix (column-major).
    public func setMatrix(_ entity: Entity, _ m: simd_float4x4) {
        guard hasEngine else { return }
        Core.setMatrix(entityId: entity.id, m)
    }

    public func setVisible(_ entity: Entity, _ visible: Bool) {
        guard hasEngine else { return }
        Core.setVisible(entityId: entity.id, visible)
    }

    /// The pose of the scene's camera (its world matrix).
    public func setCameraMatrix(_ scene: Scene3D, _ m: simd_float4x4) {
        guard hasEngine else { return }
        Core.setCameraMatrix(sceneId: scene.id, m)
    }

    /// A projection computed by the caller (ARKit's `projectionMatrix(for:viewportSize:zNear:zFar:)`),
    /// with the near / far it was built with, in place of the scene's fov projection.
    public func setProjection(_ scene: Scene3D, _ m: simd_float4x4, near: Float, far: Float) {
        guard hasEngine else { return }
        Core.setCameraProjectionMatrix(sceneId: scene.id, m, near: near, far: far)
    }

    /// Back to the scene's own (fov) projection.
    public func clearProjection(_ scene: Scene3D) {
        guard hasEngine else { return }
        Core.clearCameraProjectionMatrix(sceneId: scene.id)
    }

    /// The scene's background: `texture` behind everything through `uv`, the affine map from the
    /// viewport's normalized coordinates (0,0 top-left) to the texture's, row-major
    /// [a, b, tx, c, d, ty] (ARKit's `displayTransform(for:viewportSize:)` inverted). nil = none.
    public func setBackground(_ scene: Scene3D, _ texture: ExternalTexture?, uv: [Float] = [1, 0, 0, 0, 1, 0]) {
        guard hasEngine, uv.count == 6 else { return }
        let live = texture?.isLive == true ? texture : nil
        backgrounds[scene.id] = live
        Core.setSceneBackground(sceneId: scene.id, texture: live?.id, uv: uv)
    }

    /// A texture the caller streams frames into; nil without the 3D engine.
    public func createExternalTexture() -> ExternalTexture? {
        guard hasEngine, let id = Core.createExternalTexture() else { return nil }
        return ExternalTexture(id: id, generation: generation, gl: self)
    }

    /// `body` before each frame, on the main thread (the display link, before the runtime's tick:
    /// what it writes is in that frame), until the returned Cancel — or the world swap.
    @discardableResult
    public func onFrame(_ body: @escaping () -> Void) -> Cancel {
        let id = nextBody
        nextBody += 1
        bodies.append((id, body))
        return { [weak self] in self?.bodies.removeAll { $0.id == id } }
    }

    /// The scene's view: its size in points (the engine's viewport of the scene over the density the
    /// scene view set) and the display's turn. Read it each frame (`onFrame`) and follow a change.
    public func viewport(_ scene: Scene3D) -> Viewport {
        let size = hasEngine ? Core.sceneViewport(sceneId: scene.id) : (width: 0, height: 0)
        return Viewport(width: CGFloat(size.width), height: CGFloat(size.height), rotation: rotation())
    }

    /// The composite of the scene's next frame (the scene and its overlays — not the UI over them):
    /// RGBA8, top row first, width, height; nil (0 × 0) when the scene is not the one presented or
    /// changes first. On the main thread, with a copy.
    public func readPixels(_ scene: Scene3D, _ then: @escaping (_ rgba: Data?, _ width: Int, _ height: Int) -> Void) {
        guard hasEngine else { then(nil, 0, 0); return }
        Core.readPixels(sceneId: scene.id, then)
    }

    // MARK: - the host's side

    /// Before the runtime's tick (LeCodesEngine.tick).
    func frame() {
        guard !bodies.isEmpty else { return }
        for (_, body) in bodies { body() }
    }

    /// The world swap: a plugin's session is the world's, and so are its frame bodies.
    func worldChanged() {
        bodies.removeAll()
    }

    /// HostGL.engineCreated: the textures and the backgrounds were the old engine's.
    func engineRebuilt() {
        generation += 1
        backgrounds.removeAll()
    }

    /// The interface orientation of the stage's window scene (the foreground one while the stage has
    /// no window) as degrees.
    private func rotation() -> Int {
        let scene = stage?.window?.windowScene ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        switch scene?.interfaceOrientation {
        case .landscapeRight?: return 90
        case .portraitUpsideDown?: return 180
        case .landscapeLeft?: return 270
        default: return 0
        }
    }

    fileprivate func textureClosed(_ texture: ExternalTexture) {
        for (sceneId, shown) in backgrounds where shown === texture {
            backgrounds[sceneId] = nil
            Core.setSceneBackground(sceneId: sceneId, texture: nil, uv: [1, 0, 0, 0, 1, 0])
        }
    }
}
