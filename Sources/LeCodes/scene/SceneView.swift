// The presented 3D scene's view — the twin of hosts/android's CreatorGLView (a SurfaceView) and of
// the old host's CreatorGLView (an MTKView with its own draw loop): a plain view whose layer is the
// CAMetalLayer Filament presents into. No draw loop of its own — the RUNTIME renders inside
// Core.runTick (the engine's display link), so this view owns only the swap chain (created when it
// is mounted, destroyed when it leaves: the engine keeps one), the drawable size (the bounds × the
// display scale × the scene's render scale, re-checked before every frame — only the host can size
// the drawable) and the touches of the scene: a touch on it is the 3D pick (Core.emitTouchStart —
// the runtime raycasts), the moves of a pointer a JS listener took (TouchHandlers, the same track
// table the UI's touches use), the end and the click.
import LeCodesCore
import LeCodesUIKit
import QuartzCore
import UIKit

public final class SceneView: UIView {
    public override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public private(set) var ownsSwapChain = false
    private var appliedDrawable = CGSize.zero
    private var positions: [Int32: CGPoint] = [:]

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.device = MetalDevice.shared
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    // MARK: - the swap chain

    /// The engine's swap chain over this layer (the previous one goes: the engine holds one). The
    /// viewport follows on the next frame, not here: this runs inside HostUI.openView, BEFORE the
    /// runtime has opened the scene (glDestPresent comes after the callback), and the engine sizes
    /// the OPEN scene's camera with the viewport — Android's surfaceChanged is asynchronous for
    /// the same reason. Also the re-bind after an engine rebuild (HostGL.engineCreated).
    func createSwapChain() {
        Core.createSwapChain(layer: Unmanaged.passUnretained(metalLayer).toOpaque())
        ownsSwapChain = true
        appliedDrawable = .zero
    }
    /// The view leaves the screen: the frame stops, the swap chain goes. Idempotent.
    func destroySwapChain() {
        guard ownsSwapChain else { return }
        ownsSwapChain = false
        Core.destroySwapChain()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = displayScale
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        applyDrawableSize()
    }

    /// Before each frame (the engine's tick): the scene's render scale is engine-owned
    /// (SceneOptions.renderScale, per scene, re-read cheaply) and only the host can size the drawable.
    func prepareFrame() { applyDrawableSize() }

    private var displayScale: CGFloat {
        if let s = window?.screen.scale, s > 0 { return s }
        let t = traitCollection.displayScale
        return t > 0 ? t : UIScreen.main.scale
    }

    /// The drawable at bounds × scale × renderScale (whole px, at least 1×1); the viewport and the
    /// density (device px per point: the pick divides by it) follow a change. A transient zero /
    /// NaN size mid-rotation never reaches the engine (an inf viewport corrupts the render pass).
    private func applyDrawableSize() {
        // Only with the scene open: the viewport sizes the open scene's camera (see createSwapChain).
        guard ownsSwapChain, Core.sceneOpen, bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return }
        let scale = displayScale
        let rs = CGFloat(min(1, max(0.1, Core.sceneRenderScale)))
        let target = CGSize(width: (bounds.width * scale * rs).rounded(), height: (bounds.height * scale * rs).rounded())
        guard target.width >= 1, target.height >= 1, target != appliedDrawable else { return }
        appliedDrawable = target
        metalLayer.drawableSize = target
        Core.setViewport(width: UInt32(target.width), height: UInt32(target.height))
        Core.setDensityGL(x: Float(target.width / bounds.width), y: Float(target.height / bounds.height))
    }

    /// The viewport last pushed (device px), for a test.
    public var drawableSize: CGSize { appliedDrawable }

    // MARK: - touches (the 3D scene's pick + the tracked gesture)

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        for t in touches { pointerDown(TouchPipeline.pointerId(t), at: t.location(in: self)) }
    }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        for t in touches { pointerMove(TouchPipeline.pointerId(t), to: t.location(in: self)) }
    }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        for t in touches { pointerUp(TouchPipeline.pointerId(t), at: t.location(in: self)) }
    }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        for t in touches { pointerCancel(TouchPipeline.pointerId(t)) }
    }

    /// The pick: the runtime raycasts the scene and answers through HostUI.touchHandler when a
    /// listener took the gesture (TouchHandlers). Points in this view's space (= the root's: fullscreen).
    public func pointerDown(_ pointerId: Int32, at p: CGPoint) {
        Core.emitTouchStart(fingerId: pointerId, x: Float(p.x), y: Float(p.y))
        positions[pointerId] = p
    }
    public func pointerMove(_ pointerId: Int32, to p: CGPoint) {
        guard let track = TouchHandlers.get(pointerId), track.hasMove else { return }
        let prev = positions[pointerId]
        let dx = prev.map { p.x - $0.x } ?? 0, dy = prev.map { p.y - $0.y } ?? 0
        Core.touchMove(pointerId: pointerId, x: Float(p.x), y: Float(p.y), deltaX: Float(dx), deltaY: Float(dy))
        positions[pointerId] = p
    }
    public func pointerUp(_ pointerId: Int32, at p: CGPoint) {
        let prev = positions.removeValue(forKey: pointerId)
        let dx = prev.map { p.x - $0.x } ?? 0, dy = prev.map { p.y - $0.y } ?? 0
        TouchHandlers.remove(pointerId)
        Core.touchEnd(pointerId: pointerId, x: Float(p.x), y: Float(p.y), deltaX: Float(dx), deltaY: Float(dy))
        Core.emitTouchClick(fingerId: pointerId, x: Float(p.x), y: Float(p.y))
    }
    public func pointerCancel(_ pointerId: Int32) {
        positions[pointerId] = nil
        TouchHandlers.remove(pointerId)
        Core.touchCancel(pointerId: pointerId)
    }
}
