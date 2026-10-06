// The back swipe is the SYSTEM's (2026-09-29, docs/tree.md "Back"):
// UINavigationController's own interactive pop, with its parallax, its dim and its landing at the
// finger's speed, whatever they are on the user's iOS — not an imitation of it, and never the
// transition the screen came with.
//
// This type is a WORKAROUND, and the whole of it: UIKit gives the system's pop to nobody but a
// navigation controller, so one is used for the gesture and for nothing else. It owns NO stack —
// the runtime does — and nothing outside this file names it: whoever mounts the swipe adds `view`
// like any view (it finds the controller it sits in by itself), and the one who knows what a
// back does is asked three questions (SystemBackSwipeDelegate). If UIKit ever offers the pop by
// itself, this file is what gets replaced.
//
// Two owners, the same type and the same three questions (the plan's decision 16): the app root
// (LeCodesView: the router's back) and a pager (PagerView: the pop of its drilled-in tab). They
// nest — a pager sits inside the root — and both recognizers hear a touch at the screen's edge;
// each asks its delegate, who asks the runtime what a back would do, so one of them begins.
//
// At rest the navigation controller holds ONE controller, the stage, whose view is the view that
// slides: the app root. When the system's recognizer is about to begin, the delegate is asked
// what a back reveals and puts it into a page, which goes UNDER the stage; UIKit pops the stage
// over it under the finger. At the release UIKit says whether the pop lands or runs back, and a
// landing asks the delegate for the back AT ONCE (the runtime's rule: a back is made at the
// release, not when an animation ends). When the pop is over the delegate takes the revealed view
// in and the stage is the one controller again — in one turn of the run loop, the same pixels.
// An answer that keeps the stage (a screen's own onBack handler that does not pop) arrives when
// UIKit is already landing the pop, which cannot be turned round: the stage is pushed back.
import UIKit

public protocol SystemBackSwipeDelegate: AnyObject {
    /// The finger arrives at the edge. What a back would reveal goes into `page`, laid out at the
    /// stage's size, with nothing told to the runtime; false = a back reveals nothing, no swipe.
    func backSwipeReveals(in page: UIView) -> Bool
    /// The finger lifted and UIKit lands the pop: the back is made NOW. true = what the page holds
    /// is what is shown from now on; false = the stage stays what is shown.
    func backSwipeReleased() -> Bool
    /// UIKit's pop is over. `taken`: what the page holds comes into the stage now (the pop landed
    /// and the answer was true); otherwise it is discarded — the pop ran back, or the stage
    /// comes back.
    func backSwipeLanded(taken: Bool)
}

public final class SystemBackSwipe: NSObject, UIGestureRecognizerDelegate, UINavigationControllerDelegate {
    /// What the owner mounts: the stage inside the gesture's engine, as a view.
    public private(set) lazy var view: UIView = Mount(navigation)
    /// Named by this file alone (and by the tests of it).
    let navigation: UINavigationController
    private let stage: UIViewController
    private weak var delegate: SystemBackSwipeDelegate?

    /// One swipe, from the touch that begins it to the end of UIKit's pop.
    private enum Phase {
        case idle
        /// The page is under the stage; UIKit has not begun its pop.
        case armed(UIViewController)
        /// UIKit's pop follows the finger.
        case popping(UIViewController)
        /// The finger lifted: UIKit lands the pop or runs it back. `shown` = the delegate's answer.
        case landing(UIViewController, shown: Bool)
    }
    private var phase = Phase.idle

    public init(stage view: UIView, delegate: SystemBackSwipeDelegate) {
        self.delegate = delegate
        stage = Stage(view)
        navigation = UINavigationController(rootViewController: stage)
        super.init()
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.delegate = self
        navigation.interactivePopGestureRecognizer?.delegate = self
        navigation.interactivePopGestureRecognizer?.addTarget(self, action: #selector(onRecognizer(_:)))
    }

    /// The engine as a view. UIKit wants a controller inside a controller: the one this view
    /// sits in is found when it comes to a window, and let go when it leaves.
    private final class Mount: UIView {
        private let controller: UIViewController
        init(_ controller: UIViewController) {
            self.controller = controller
            super.init(frame: .zero)
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(controller.view)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            controller.view.place(bounds)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var owner: UIViewController?
            if window != nil {
                var r = superview as UIResponder?
                while let cur = r, owner == nil { owner = cur as? UIViewController; r = cur.next }
            }
            guard controller.parent !== owner else { return }
            if controller.parent != nil {
                controller.willMove(toParent: nil)
                controller.removeFromParent()
            }
            if let owner {
                owner.addChild(controller)
                controller.didMove(toParent: owner)
            }
        }
    }

    /// The stage: the view that slides, as a controller's view.
    private final class Stage: UIViewController {
        private let content: UIView
        init(_ content: UIView) {
            self.content = content
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
        override func loadView() { view = content }
    }

    /// What shows behind the two pages while UIKit moves them (the system's pop rounds their
    /// corners): the color of the screen that is shown, and of the revealed one under a finger.
    public var backdrop: UIColor? {
        get { navigation.view.backgroundColor }
        set { navigation.view.backgroundColor = newValue }
    }

    /// A swipe has the views, from its first touch to the end of UIKit's pop.
    public var inFlight: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// Something else takes the stage while the finger is down: the recognizer is cancelled, UIKit
    /// runs the pop back and its end clears up. After the release the pop is landing — nothing to
    /// call off, the landing sorts out what is shown by then.
    public func callOff() {
        switch phase {
        case .armed, .popping:
            guard let g = navigation.interactivePopGestureRecognizer, g.isEnabled else { return }
            g.isEnabled = false
            g.isEnabled = true
        case .idle, .landing:
            break
        }
    }

    // MARK: - the recognizer

    public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard case .idle = phase, navigation.viewControllers.count == 1, navigation.transitionCoordinator == nil,
              let delegate, !TouchClaims.blocks(g) else { return false }
        let page = UIViewController()
        page.loadViewIfNeeded()
        page.view.place(stage.view.bounds)
        guard delegate.backSwipeReveals(in: page.view) else { return false }
        phase = .armed(page)
        backdrop = page.view.backgroundColor
        navigation.setViewControllers([page, stage], animated: false)
        // A recognizer that FAILS after this answer (another one took the touch) reports it to
        // nobody: by the next turn of the run loop it has begun, or it never will.
        DispatchQueue.main.async { [weak self, weak g] in
            guard let self, let g, g.state == .possible || g.state == .failed else { return }
            self.disarm()
        }
        return true
    }

    /// The recognizer is done. A swipe still armed then is one UIKit never began a pop for: it is
    /// taken apart here, as a pop that ran back — nothing else would ever end it, and no swipe
    /// could begin after it.
    @objc private func onRecognizer(_ g: UIGestureRecognizer) {
        switch g.state {
        case .ended, .cancelled, .failed:
            DispatchQueue.main.async { [weak self] in self?.disarm() }
        default:
            break
        }
    }
    func disarm() {
        guard case .armed = phase else { return }
        print("[LeCodes] back swipe: no pop began, taken apart")
        landed(finished: false)
    }

    // MARK: - the pop

    public func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        guard case .armed(let page) = phase, viewController === page, let coordinator = navigationController.transitionCoordinator else { return }
        phase = .popping(page)
        coordinator.notifyWhenInteractionChanges { [weak self] context in
            self?.released(commit: !context.isCancelled)
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            self?.landed(finished: !context.isCancelled)
        }
    }

    /// The finger lifted and UIKit decided: a pop that lands asks for the back now, one that runs
    /// back asks nothing. The phase changes BEFORE the question — what the answer makes of the
    /// stage is not a reason to call the swipe off.
    func released(commit: Bool) {
        let page: UIViewController
        switch phase {
        case .armed(let p), .popping(let p): page = p
        case .idle, .landing: return
        }
        phase = .landing(page, shown: false)
        guard commit, delegate?.backSwipeReleased() ?? false, case .landing = phase else { return }
        phase = .landing(page, shown: true)
    }

    /// UIKit's report: the pop landed, or ran back.
    func landed(finished: Bool) {
        // A pop that was never interactive, or whose interaction never changed (the finger's lift
        // decided at once): the release is told here, before the landing.
        released(commit: finished)
        guard case .landing(let page, let shown) = phase else { return }
        phase = .idle
        delegate?.backSwipeLanded(taken: finished && shown)
        // Whatever the delegate left in the page goes with the page.
        if page.isViewLoaded { page.view.subviews.forEach { $0.removeFromSuperview() } }
        // The stage was slid away and stays what is shown: it comes back the way it left.
        navigation.setViewControllers([stage], animated: finished && !shown)
    }
}
