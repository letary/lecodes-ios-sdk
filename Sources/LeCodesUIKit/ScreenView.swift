// A screen root's view: a NodeView that takes the touches no interactive child claimed when the
// screen itself is interactive (TREE_FLAG_INTERACTIVE: the SDK's onTouchStart on a screen) —
// inside its OWN bounds only; the widening exists so overflowing children stay reachable, never so
// the screen claims touches outside its box. A screen has no click.
import LeCodesCore
import UIKit

class ScreenView: NodeView, PointerTarget {
    private var touches: [Int32: TouchPosition] = [:]

    /// The screen's `dim` (a transition's pose: how dark the screen UNDER the other one gets): a
    /// black layer over the content and the children, made when the first dim arrives.
    private(set) var dimLayer: CALayer?

    /// The layer a dim lives on — made here for a host-played track too, whose first value is 0.
    @discardableResult
    func ensureDimLayer() -> CALayer {
        if let dimLayer { return dimLayer }
        let newLayer = CALayer()
        newLayer.backgroundColor = UIColor.black.cgColor
        newLayer.opacity = 0
        newLayer.zPosition = 1   // over the children, whose layers are this layer's sublayers too
        newLayer.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        newLayer.frame = bounds
        layer.addSublayer(newLayer)
        dimLayer = newLayer
        return newLayer
    }

    func setDim(_ value: CGFloat) {
        if dimLayer == nil && value <= 0 { return }
        ensureDimLayer().opacity = Float(min(max(value, 0), 1))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dimLayer?.frame = bounds
    }

    private var interactive: Bool { node?.has(TreeEvents.TREE_FLAG_INTERACTIVE) ?? false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil { return hit }
        return interactive && bounds.contains(point) && !isHidden && alpha >= 0.01 && isUserInteractionEnabled ? self : nil
    }

    private var touchNode: Int { node.map { $0.isRemoved ? 0 : $0.id } ?? 0 }

    func pointerDown(_ pointerId: Int32, at p: CGPoint) {
        guard interactive else { return }
        TouchPipeline.start(node: touchNode, pointerId: pointerId, at: p, touches: &touches)
    }
    func pointerMove(_ pointerId: Int32, to p: CGPoint) {
        TouchPipeline.move(node: touchNode, pointerId: pointerId, to: p, touches: &touches)
    }
    func pointerUp(_ pointerId: Int32, at p: CGPoint) {
        TouchPipeline.end(node: touchNode, pointerId: pointerId, at: p, touches: &touches, sendClick: false)
    }
    func pointerCancel(_ pointerId: Int32) {
        TouchPipeline.cancel(node: touchNode, pointerId: pointerId, touches: &touches)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointerDown(TouchPipeline.pointerId(t), at: rootPoint(of: t)) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointerMove(TouchPipeline.pointerId(t), to: rootPoint(of: t)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointerUp(TouchPipeline.pointerId(t), at: rootPoint(of: t)) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointerCancel(TouchPipeline.pointerId(t)) }
    }
}
