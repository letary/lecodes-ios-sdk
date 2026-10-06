// A UI tween track the runtime handed the renderer to play (HostUI.tweenClaim): Core Animation
// interpolates the track's samples on the render server, at the display's own rate, untouched by
// whatever the main thread's frame costs — what the old host's UIView.animate blocks gave animateTo,
// on the runtime's animation model. The runtime keeps the clock, the events and the resting value;
// it writes the prop ONCE at every release (the final value at the end, the pose of the moment on a
// control or a takeover), and `release` applies that write before it removes the animation, so the
// model already shows what the animation showed — nothing flashes. Only props with a layer
// property are taken: opacity, backgroundColor, transform (each sample composed the way BoxPaint
// composes the node's own matrix: the pivot folded in against the box of the moment, the sheet
// offset on top), and a widget's overlayColor — the scrim's background, on the scrim's own layer,
// when the scrim already exists (a first overlayColor CREATES the scrim, which is the runtime's
// write to make), and a screen's dim, on its dim layer. A screen TRANSITION arrives here like any
// other tween: it is the runtime's tracks on the two roots' transform / opacity / dim
// (docs/tree.md "Transitions") — the renderer plays none of its own. Everything else — and every track under a fixed-clock run, where the frames ARE
// the clock — answers false and stays the runtime's, one write per frame.
//
// The display's FULL rate (120 Hz on ProMotion) is not an animation's by default: an animation made
// by hand carries no frame rate hint and an iPhone shows it at 60, and a hint of our own
// (preferredFrameRateRange) is honoured there only under an Info.plist key of the embedding app's —
// which a library does not ask for. The animations UIKIT makes carry the hint the system honours
// (probed 2026-09-29: range 30–120 and its reason, on UIView.animate, UIViewPropertyAnimator and
// UIView.animateKeyframes alike; a bare layer animated inside a UIKit block gets none). So a track
// plays on an animation UIKit made — `stamped` — with the track's own samples and timing put in:
// playing it through UIKit's animators instead would lose the hold at the end (a keyframe animation
// is removed when it lands, `pausesOnCompletion` or not), the repeats (ignored inside an animator)
// and the explicit first sample.
import LeCodesCore
import UIKit

enum LayerTween {
    /// The animation key on the layer, per prop: a claim on a prop already claimed replaces it.
    static func key(_ prop: String) -> String { "lc.tween." + prop }

    /// The layer a prop's animation lives on: the node's view, the scrim's for a widget's
    /// overlayColor, the dim layer for a screen's dim.
    static func layer(of node: UINode, prop: String) -> CALayer? {
        if prop == "overlayColor" { return (node as? UINodeWidget)?.overlay?.layer }
        if prop == "dim" { return (node.view as? ScreenView)?.ensureDimLayer() }
        return node.view.layer
    }

    static func claim(_ node: UINode, prop: String, lanes: Int, samples: UnsafeBufferPointer<Float>, durationMs: Float, delayMs: Float,
                      iterations: Int32, pingPong: Bool, rate: Float) -> Bool {
        guard Animations.enabled, !node.isRemoved, durationMs > 0, lanes > 0, samples.count >= lanes * 2,
              let layer = layer(of: node, prop: prop) else { return false }
        let n = samples.count / lanes
        let keyPath: String
        var values: [Any] = []
        values.reserveCapacity(n)
        let colors = { for i in 0..<n {
            let b = i * 4
            values.append(UIColor(red: CGFloat(samples[b]), green: CGFloat(samples[b + 1]), blue: CGFloat(samples[b + 2]), alpha: CGFloat(samples[b + 3])).cgColor)
        } }
        switch (prop, lanes) {
        case ("opacity", 1), ("dim", 1):
            keyPath = "opacity"
            for i in 0..<n { values.append(NSNumber(value: samples[i])) }
        case ("backgroundColor", 4), ("overlayColor", 4):
            keyPath = "backgroundColor"
            colors()
        case ("transform", 9):
            keyPath = "transform"
            for i in 0..<n {
                let b = i * 9   // the paint record's column-major 3x3
                let m = CGAffineTransform(a: CGFloat(samples[b]), b: CGFloat(samples[b + 1]), c: CGFloat(samples[b + 3]), d: CGFloat(samples[b + 4]),
                                          tx: CGFloat(samples[b + 6]), ty: CGFloat(samples[b + 7]))
                values.append(NSValue(caTransform3D: CATransform3DMakeAffineTransform(node.box.composed(m))))
            }
        default:
            return false
        }
        let anim = animation(keyPath)
        anim.values = values
        anim.keyTimes = (0..<n).map { NSNumber(value: Double($0) / Double(n - 1)) }
        anim.calculationMode = .linear
        anim.duration = CFTimeInterval(durationMs) / 1000
        if delayMs > 0 { anim.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + CFTimeInterval(delayMs) / 1000 }
        // Held at both ends and never self-removed: the first sample through the delay (the model
        // holds the same value — the runtime's initial pose), the last one until the runtime's own
        // end lands the model and releases (its clock and CA's differ by up to a frame).
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        anim.repeatCount = iterations < 0 ? .infinity : Float(iterations)
        anim.autoreverses = pingPong && iterations != 1
        anim.speed = rate
        layer.add(anim, forKey: key(prop))
        return true
    }

    /// A keyframe animation that carries what UIKit's own carry — the frame rate hint — and nothing
    /// else of UIKit's; a plain one where UIKit makes none (the display then plays it at 60 Hz).
    private static func animation(_ keyPath: String) -> CAKeyframeAnimation {
        if stamped == nil { stamped = makeStamped() }
        guard let made = stamped?.copy() as? CAKeyframeAnimation else { return CAKeyframeAnimation(keyPath: keyPath) }
        made.keyPath = keyPath
        return made
    }

    private static var stamped: CAKeyframeAnimation?

    private static func makeStamped() -> CAKeyframeAnimation? {
        let enabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
        defer { UIView.setAnimationsEnabled(enabled) }
        let view = UIView()
        UIView.animateKeyframes(withDuration: 1, delay: 0, options: [.calculationModeLinear]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) { view.alpha = 0 }
        }
        let made = view.layer.animation(forKey: "opacity")?.mutableCopy() as? CAKeyframeAnimation
        view.layer.removeAllAnimations()
        // UIKit's bookkeeping stays with UIKit: its delegate would report the landing of OUR
        // animations to a state that is gone.
        made?.delegate = nil
        made?.timingFunction = nil
        made?.timingFunctions = nil
        made?.beginTime = 0
        // …and a track's samples are absolute values, whatever UIKit chooses for its own.
        made?.isAdditive = false
        made?.isCumulative = false
        return made
    }

    /// The channel is the runtime's again: its landing write is in the node's record — apply it,
    /// THEN drop the animation, in this transaction, so the presentation moves from the animation's
    /// value to the same value in the model.
    static func release(_ node: UINode, prop: String) {
        guard !node.isRemoved else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        PaintBatch.applyPending(node)
        layer(of: node, prop: prop)?.removeAnimation(forKey: key(prop))
        CATransaction.commit()
    }

    /// Is a claimed track playing on this node's layer for `prop`? (tests)
    static func isPlaying(_ node: UINode, prop: String) -> Bool { layer(of: node, prop: prop)?.animation(forKey: key(prop)) != nil }
}
