// The presented 2D scene's view — the twin of hosts/android's Creator2DView (a SurfaceView the
// engine draws into) and of the old host's Creator2DView (an MTKView). creator-2d's Metal arm draws
// the presented scene into its PRESENT TARGET (an IOSurface-backed texture this view owns through
// a Scene2DSurface, ping-ponged) and the surface's CALayer shows it: no CAMetalLayer, no drawable
// / depth texture per frame — the same path the `UIImage(scene2d)` nodes use, one frame driver
// (renderFrame, from the engine's tick after the runtime's, with the runtime's own 2D frame:
// Core.scene2dRenderFrame runs the SDK's per-frame hooks, steps the simulation and draws).
//
// Touches go raw to the `_creator2d` pointer channel (Core.scene2dEmitPointer — the SDK hit-tests
// and tracks): the UI widgets above are separate views that consume their own touches first, so
// whatever reaches this view is the scene's. phase: 0 down, 1 move, 2 up, 3 cancel; points.
import LeCodesCore
import LeCodesUIKit
import UIKit

public final class Scene2DView: UIView {
    public let surface = Scene2DSurface()
    private weak var engine: LeCodesEngine?

    init(engine: LeCodesEngine?) {
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        layer.addSublayer(surface.layer)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer.frame = bounds
        surface.layer.contentsScale = displayScale
        CATransaction.commit()
    }

    private var displayScale: CGFloat {
        if let s = window?.screen.scale, s > 0 { return s }
        let t = traitCollection.displayScale
        return t > 0 ? t : UIScreen.main.scale
    }

    /// One frame of the presented scene into this view's surface: the target at the box's pixel
    /// size (the viewport; the density = px per point, so camera zoom means logical px), the
    /// runtime's 2D frame, the surface shown. False when the view has no size yet / no engine
    /// target — the caller renders the frame elsewhere so the simulation still steps.
    @discardableResult
    func renderFrame(nowMs: Int64) -> Bool {
        let scale = displayScale
        let pw = Int((bounds.width * scale).rounded()), ph = Int((bounds.height * scale).rounded())
        guard pw >= 1, ph >= 1, surface.resize(pw, ph), let target = surface.beginFrame() else { return false }
        Core.scene2dSetPresentTarget(target)
        Core.scene2dSetViewport(width: pw, height: ph)
        Core.scene2dSetDensity(Float(scale))
        Core.scene2dRenderFrame(nowMs: nowMs)
        surface.present()
        return true
    }

    // MARK: - touches → the _creator2d pointer channel

    private func forward(_ phase: Int32, _ touches: Set<UITouch>, _ event: UIEvent?) {
        let precise = engine?.preciseTouch ?? false
        for touch in touches {
            let id = TouchPipeline.pointerId(touch)
            // Precise touch (device.setPreciseTouch): on MOVE replay every coalesced sample the
            // digitizer captured since the last frame — the sensor runs faster than the display, and
            // one point per callback undersamples fast strokes (the web's pointermove parity).
            if phase == 1, precise, let coalesced = event?.coalescedTouches(for: touch) {
                for c in coalesced {
                    let p = c.location(in: self)
                    Core.scene2dEmitPointer(phase: phase, pointerId: id, x: Float(p.x), y: Float(p.y))
                }
            } else {
                let p = touch.location(in: self)
                Core.scene2dEmitPointer(phase: phase, pointerId: id, x: Float(p.x), y: Float(p.y))
            }
        }
    }
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesBegan(touches, with: event); forward(0, touches, event) }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesMoved(touches, with: event); forward(1, touches, event) }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesEnded(touches, with: event); forward(2, touches, event) }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesCancelled(touches, with: event); forward(3, touches, event) }

    /// The scripted pointer (a check runner): the same channel.
    public func pointer(phase: Int32, _ pointerId: Int32, at p: CGPoint) {
        Core.scene2dEmitPointer(phase: phase, pointerId: pointerId, x: Float(p.x), y: Float(p.y))
    }
}
