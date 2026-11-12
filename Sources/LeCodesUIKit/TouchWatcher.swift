// A recognizer that WATCHES the touches of a view a plugin draws (a host node's control, a native
// destination's view) and never recognizes: the view keeps every gesture of its own, the runtime is
// only told of each finger — its touchStart, and what a track a listener took is fed (the moves, the
// end, the cancel). It takes no touch from the view, neither prevents a recognizer nor is prevented
// by one, and stays `.possible` while a finger is down.
//
// Every finger is its own pointer (TouchPipeline's multitouch rule 1): each UITouch is reported by
// itself, under TouchPipeline.pointerId.
import UIKit
import UIKit.UIGestureRecognizerSubclass

public final class TouchWatcher: UIGestureRecognizer {
    public var onDown: ((_ pointerId: Int32, _ touch: UITouch) -> Void)?
    public var onMove: ((_ pointerId: Int32, _ touch: UITouch) -> Void)?
    public var onUp: ((_ pointerId: Int32, _ touch: UITouch) -> Void)?
    public var onCancel: ((_ pointerId: Int32) -> Void)?

    /// The fingers being watched, by pointer id.
    private var active = Set<Int32>()

    public init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    public override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    public override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            let id = TouchPipeline.pointerId(t)
            active.insert(id)
            onDown?(id, t)
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            let id = TouchPipeline.pointerId(t)
            if active.contains(id) { onMove?(id, t) }
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            let id = TouchPipeline.pointerId(t)
            if active.remove(id) != nil { onUp?(id, t) }
        }
        settle()
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            let id = TouchPipeline.pointerId(t)
            if active.remove(id) != nil { onCancel?(id) }
        }
        settle()
    }

    /// The last finger left: nothing was recognized, UIKit resets the recognizer for the next touch.
    private func settle() {
        if active.isEmpty { state = .failed }
    }

    /// UIKit ended the sequence itself with fingers still counted: their touches are over all the same.
    public override func reset() {
        super.reset()
        let left = active
        active.removeAll()
        for id in left { onCancel?(id) }
    }
}
