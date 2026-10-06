// The root view of the iOS host — the twin of hosts/android's LeCodesView: the app-root coordinate
// space (what widgets position in and getBoundingRect reports against), the view the presented
// destination's view is mounted under, the renderer's per-frame layout pass (Core.layoutFrame over
// every live root → LayoutBatch → the apply walk from the roots), the safe-area pushes, the
// `resize` rule, the keyboard (KeyboardLayoutController), the toasts, and the pointer entry a
// check runner drives (the same hit-test a UITouch goes through). Layering invariant, like
// Android's: surface-backed destinations (the 3D scene's Metal layer, the 2D scene's surface, a
// native view, a promoted video) at the bottom and never animated, screens above them (the only
// side a transition moves), widgets on top.
//
// One destination is current at a time (the runtime owns the stack). This view animates no change
// of destination itself: a transition is the runtime's tween tracks on the two screen roots' own
// transform / opacity / dim (docs/tree.md "Transitions"), which reach the views like any other
// paint — or play on Core Animation where the renderer claims them. Its part is three calls:
// openDest mounts the destination over what is shown or under it and KEEPS what was shown;
// dropDest unmounts the one that left, when the runtime says its transition landed; closeDest says
// nothing is current.
//
// The back swipe is the SYSTEM's — iOS's "back", the twin of Android's button, and it looks like
// the platform's pop whatever transition the screen came with. The gesture is the renderer's
// SystemBackSwipe, which slides this whole view; how it does that is its own business. This view
// answers its three questions (SystemBackSwipeDelegate): what a back reveals (Core.backTarget —
// the pull exists for this; the revealed screen's view is handed out), the back itself AT THE
// RELEASE (Core.backCommitted — the same chain the button runs, so a screen's `onBack` handler
// answers here; the change it makes plays no transition of the runtime's, the gesture was it),
// and the landing, when the revealed view comes in here. A handler that keeps its screen (a
// confirm dialog, a no-op) answers with no pop; a swipe that ran back tells the runtime nothing.
// A drilled-in PAGER's pop is the same swipe, the pager's own (PagerView answers it): both hear
// a touch at the edge, and the runtime's answer — a router's pop, or a pager's — says whose it is.
import AVFoundation
import LeCodesCore
import LeCodesUIKit
import UIKit

public final class LeCodesView: UIView, UIRootHost, SystemBackSwipeDelegate {
    public private(set) weak var engine: LeCodesEngine?
    /// The presented screen's root, nil while a scene / native view / video is the destination.
    public private(set) var currentScreen: UINode?
    private var screenView: UIView?
    /// The presented surface (a native view's instance, a video's player layer), at the bottom.
    private var surfaceView: UIView?
    /// The node embedding the promoted native view's instance, which takes it back on close.
    private var surfaceOwner: UINodeNativeView?
    /// The presented native view's instance id (DestKind.native), for the owner lookup at release.
    private var surfaceViewId: Int?
    /// The scene views, kept while their scene is open (a screen pushed over a scene pauses it: the
    /// view leaves and comes back with its swap chain / surface when the scene is presented again).
    public private(set) var sceneView: SceneView?
    public private(set) var scene2dView: Scene2DView?
    /// The destination the mounted surface was opened as: what its dropDest names.
    private var surfaceKind = DestKind.none
    private var surfaceId = 0
    /// A scene closed (HostGL.closeScene / HostScene2d.close2DScene) with its view still mounted:
    /// the view goes with the destination's dropDest — or, when no change of destination followed
    /// the close (nothing will drop it), by the posted flush.
    private var pendingSurfaceRelease = false
    private var lastSize = CGSize.zero
    private lazy var widgets = WidgetHost(root: self)
    var widgetHost: WidgetHost { widgets }
    lazy var keyboard = KeyboardLayoutController(host: self)
    /// The presented destination's kind and id (a scene / native / video owner of a widget).
    private(set) var destKind: Int = DestKind.none
    private(set) var destId: Int = 0
    /// The system's swipe over this view, when it is mounted with one (LeCodesViewController):
    /// told when something else takes the screen.
    public weak var backSwipe: SystemBackSwipe?
    /// The screen the system's swipe reveals, from its first touch to the end of its pop.
    private var swiped: Swiped?
    /// Tap-outside keyboard dismissal: observed, never consumed — the tap keeps flowing to the app.
    private lazy var dismissTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(onDismissTap(_:)))
        g.cancelsTouchesInView = false
        g.delegate = self
        return g
    }()

    public init(engine: LeCodesEngine) {
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .black
        // This view IS the app-root space; the core runs in points (density 1).
        UINode.appRoot = self
        CreatorUI.setDensity(1)
        FrameBatcher.onLayoutFrame = { [weak self] in self?.layoutFrame() }
        engine.rootView = self
        addGestureRecognizer(dismissTap)
        keyboard.start()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { nil }

    // MARK: - the frame's layout pass

    /// The runtime recalculates EVERY live root natively — the current screen at the viewport (the
    /// keyboard shrink is per root, Core.setShrunkRoot), the covered router screens, the open
    /// widget roots, the pager pages — and collects every node those passes visited into one batch;
    /// it is drained in one crossing and applied FROM THE ROOTS, so a node shifted by a change
    /// outside the view that asked for a frame is repositioned too. A pass the keyboard asked for
    /// animates its frames along the keyboard's curve.
    private func layoutFrame() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let count = Core.layoutFrame(width: Float(size.width), height: Float(size.height))
        guard count > 0 else { return }
        LayoutBatch.load()
        let apply = { LayoutBatch.applyFromRoots() }   // the screen, the widgets, the pager pages: the batch names them
        if let a = keyboard.takeAnimation(), Animations.enabled {
            UIView.animate(withDuration: a.duration, delay: 0, options: [a.curve, .beginFromCurrentState, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
        keyboard.afterLayoutFrame()
    }

    // MARK: - size, safe area

    public override var frame: CGRect { didSet { sizeChanged() } }
    public override var bounds: CGRect { didSet { sizeChanged() } }

    /// Full size on purpose: JS `resize` events describe the window, not the viewport minus the
    /// keyboard, so onResize / setConditionValue never carry the inset.
    private func sizeChanged() {
        let size = bounds.size
        guard size != lastSize, size.width > 0, size.height > 0 else { return }
        lastSize = size
        CreatorUI.setConditionValue(width: Float(size.width), height: Float(size.height))
        Core.onResize(width: Float(size.width), height: Float(size.height))
        screenView?.place(bounds)
        surfaceView?.place(bounds)
        pushSafeArea()
        if let screen = currentScreen { FrameBatcher.request(screen) }
        widgets.layoutAll()
        keyboard.applyKeyboardLayout()   // the overlaps are geometry
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // The shrunk screen's frame is the layout's (short by the keyboard), not the viewport's.
        if let sv = screenView, keyboard.shrunkRoot !== currentScreen { sv.place(bounds) }
        surfaceView?.place(bounds)
        pushSafeArea()
    }
    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        pushSafeArea()
    }
    /// A view laid out entirely inside the safe area keeps zero insets across the window attach,
    /// yet the engine needs the WINDOW's — so pushed from here too, and read from the window.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        pushSafeArea()
        // The stats line lives in the window, over everything: it follows this view in and out.
        if window != nil { engine?.statsOverlay.attach() } else { engine?.statsOverlay.detach() }
    }

    private var lastInsets = UIEdgeInsets(top: -1, left: -1, bottom: -1, right: -1)
    /// The globals stay REAL (an unfocused root keeps its safe-bottom under the keyboard); the
    /// keyboard's collapse is per root (KeyboardLayoutController restates it after every push).
    /// Insets can change with the size unchanged (boot: the first layout before the window reports
    /// real insets), so every change pushes — the paddings call re-resolves every live root's
    /// safe- / comfort- styles.
    private func pushSafeArea() {
        let insets = window?.safeAreaInsets ?? safeAreaInsets
        guard insets != lastInsets else { return }
        lastInsets = insets
        CreatorUI.setSafePaddings(top: Float(insets.top), right: Float(insets.right), bottom: Float(insets.bottom), left: Float(insets.left))
        keyboard.safeInsetsChanged(insets)
        if let screen = currentScreen { FrameBatcher.request(screen) }
    }

    // MARK: - destinations

    func openDest(_ dest: PresentedDest, above: Bool) {
        // A keyboard raised by the content being left must not survive into what replaces it.
        keyboard.dismissKeyboardForNavigation()
        // Before the branch: the incoming destination is what an attachTo owner resolves against.
        destKind = dest.kind
        destId = dest.id
        switch dest.kind {
        case DestKind.screen:
            if let node = dest.node { openScreen(node, above: above) }
        case DestKind.native:
            let (view, owner) = nativeSurface(dest)
            openSurface(view, dest, owner: owner)
        case DestKind.video:
            if let video = dest.node as? UINodeVideo { openSurface(videoSurface(video), dest) } else { leaveScreen() }
        case DestKind.scene3d:
            openSurface(sceneSurface(), dest)
        case DestKind.scene2d:
            openSurface(scene2dSurface(), dest)
        default:
            leaveScreen()
            print("[LeCodesView] unknown destination kind \(dest.kind)")
        }
        widgets.updateAttached()
    }

    /// The runtime dropped the destination that left: its transition landed (or none played). A
    /// destination that is the current one again is not dropped — the runtime lands a transition
    /// before it presents anything, so this is a drop that arrived for an earlier presentation.
    func dropDest(_ dest: PresentedDest) {
        if dest.kind == DestKind.screen {
            guard let node = dest.node, node !== currentScreen else { return }
            let view = node.view
            if let s = swiped {
                if view === s.leaving { return }   // the swipe's landing takes it
                if s.revealed === node, s.answer == .adopted { swiped?.answer = .left }
            }
            if view.superview === self { view.removeFromSuperview() }
            return
        }
        guard surfaceView != nil, surfaceKind == dest.kind, surfaceId == dest.id else { return }
        if destKind == dest.kind && destId == dest.id { return }
        releaseSurface()
    }

    /// The incoming screen was laid out by the runtime at the viewport before this call (its
    /// views may not assume a NaN-free box otherwise): mount its view over or under what is shown
    /// and apply the boxes now — a structural pass, the batch inactive, so the whole subtree is
    /// walked. What was shown stays: the runtime moves both and drops the one that left.
    private func openScreen(_ node: UINode, above: Bool) {
        if currentScreen === node { return }
        // The swipe's back: the runtime answered with the screen the finger revealed. The views
        // stay where the swipe has them until its pop is over (backSwipeLanded).
        if let s = swiped, s.answer == .asking, s.revealed === node {
            swiped?.answer = .adopted
            swiped?.leaving = screenView
            currentScreen = node
            screenView = node.view
            applyScreenBackground(node)
            return
        }
        backSwipe?.callOff()
        pendingSurfaceRelease = false
        let shown = screenView
        let newView = node.view
        // A screen built in the call that presents it (`Router.push(Detail())`) has had no frame's
        // paint sync yet: its record now — before it is the current screen, so the record's
        // background lands through the one call below, not through screenBackgroundChanged too.
        PaintBatch.applyPending(node)
        currentScreen = node
        screenView = newView
        newView.place(bounds)
        // The container's color before the screens move, so any gap they expose (a zoom's scaled
        // edge) shows the incoming screen's color rather than black.
        applyScreenBackground(node)
        // Under the screen that is leaving when the transition keeps that one on top; a surface is
        // the bottom whatever is asked.
        if let shown, !above, shown.superview === self { insertSubview(newView, belowSubview: shown) } else { addSubview(newView) }
        node.updateLayout()
        widgets.bringGlobalsToFront()
    }

    /// UIRootHost: a screen's background changed (a live re-theme). The presented one moves the
    /// backdrop and the status bar with it; while a back swipe is in flight the gesture's backdrop
    /// stays the revealed screen's (the release presents that one, openScreen's adopt branch) and
    /// the change waits for the landing (backSwipeLanded applies the current screen's).
    public func screenBackgroundChanged(_ screen: UINode) {
        guard screen === currentScreen, swiped == nil else { return }
        applyScreenBackground(screen)
    }

    /// Any gap a transition briefly exposes (the safe area, an overscroll, the rounded corners of
    /// the system's pop) shows the screen's own color instead of black; a screen with no solid
    /// background keeps the previous one. The status bar is told with it (statusBarStyle).
    private func applyScreenBackground(_ node: UINode) {
        guard let c = node.paint.backgroundColor else { return }
        let color = UIColor(rgba: c)
        backgroundColor = color
        backSwipe?.backdrop = color
        var white: CGFloat = 0, alpha: CGFloat = 0
        let style: UIStatusBarStyle = color.getWhite(&white, alpha: &alpha) && alpha > 0.5 ? (white < 0.6 ? .lightContent : .darkContent) : .default
        if style != statusBarStyle {
            statusBarStyle = style
            onStatusBarStyle?()
        }
    }

    /// The status bar's content over the presented screen: light over a dark background, dark
    /// over a light one, by the screen's own color. NOT left to the system (`.default`): iOS 26
    /// picks the color itself from what is under the bar, and starts over — dark, then a fade to
    /// what it picks — every time the view there changes: at every change of screen and at both
    /// ends of the back swipe the time blinked (seen on the phone, measured on the simulator).
    /// `.default` until a screen with a solid background is shown.
    public private(set) var statusBarStyle = UIStatusBarStyle.default
    /// The controller that shows the bar re-reads `statusBarStyle`.
    public var onStatusBarStyle: (() -> Void)?

    /// No screen is current; the view of the one that was stays until the runtime drops it.
    private func leaveScreen() {
        backSwipe?.callOff()
        screenView = nil
        currentScreen = nil
    }

    // MARK: - surfaces (a native view, a promoted video)

    /// The registerView instance's own view, fullscreen — promotion: it may be embedded in a screen
    /// right now (`owner`: its node adopts it back when this destination closes).
    private func nativeSurface(_ dest: PresentedDest) -> (view: UIView, owner: UINodeNativeView?) {
        let owner = UINodeNativeView.embedding(viewId: dest.id)
        guard let engine, let instance = engine.nativeViews.ensure(viewId: Int32(dest.id), viewName: dest.viewName ?? "", paramsJson: dest.paramsJson ?? "null") else {
            return (NativeViews.placeholder(dest.viewName ?? ""), owner)
        }
        return (instance.view, owner)
    }

    /// A second player layer over the SAME player: playback continues, the embedded node (if any)
    /// keeps showing the media, and a pop just drops this view.
    private func videoSurface(_ video: UINodeVideo) -> UIView {
        VideoSurfaceView(layer: video.makePlayerLayer())
    }

    // MARK: - the scenes (HostGL / HostScene2d + the scene destinations)

    /// The 3D scene's view, one while its scene is open (the swap chain is created when it mounts).
    private func sceneSurface() -> SceneView {
        if let v = sceneView { return v }
        let v = SceneView()
        sceneView = v
        return v
    }
    private func scene2dSurface() -> Scene2DView {
        if let v = scene2dView { return v }
        let v = Scene2DView(engine: engine)
        scene2dView = v
        return v
    }
    /// The legacy first scene.open() (HostGL.createGLView): the scene view is the presented surface
    /// from now, without a transition (the destination's openView, when it follows, finds it mounted).
    func ensureSceneView() {
        let v = sceneSurface()
        if surfaceView !== v { mountSurface(v, kind: DestKind.scene3d, id: destKind == DestKind.scene3d ? destId : 0) }
    }
    func ensureScene2dView() {
        let v = scene2dSurface()
        if surfaceView !== v { mountSurface(v, kind: DestKind.scene2d, id: destKind == DestKind.scene2d ? destId : 0) }
    }
    /// HostGL.closeScene: the 3D scene closed for good. Its view, when it is the mounted surface,
    /// goes with the destination's dropDest (a screen may be coming in over it), else by the flush.
    func sceneClosed() {
        guard let v = sceneView else { return }
        sceneView = nil
        if surfaceView === v { deferSurfaceRelease() } else { v.destroySwapChain() }
    }
    /// HostScene2d.close2DScene: the same for the 2D scene.
    func scene2dClosed() {
        guard let v = scene2dView else { return }
        scene2dView = nil
        if surfaceView === v { deferSurfaceRelease() }
    }
    /// The flush releases the surface only when the close was not part of a change of destination:
    /// the scene is still what this view presents, so no dropDest is on its way.
    private func deferSurfaceRelease() {
        pendingSurfaceRelease = true
        let kind = destKind, id = destId
        JSThread.post { [weak self] in
            guard let self, self.pendingSurfaceRelease else { return }
            self.pendingSurfaceRelease = false
            if self.destKind == kind && self.destId == id { self.releaseSurface() }
        }
    }

    /// A surface destination: `view` at the bottom, never moved. The screen that was shown is no
    /// longer current and stays above the surface until the runtime drops it. `owner` = the node
    /// a promoted native view returns to.
    private func openSurface(_ view: UIView, _ dest: PresentedDest, owner: UINodeNativeView? = nil) {
        leaveScreen()
        mountSurface(view, kind: dest.kind, id: dest.id, owner: owner)
    }

    /// A surface other than the mounted one takes the bottom (the one before it is released: a
    /// promoted native view returns to its node); a scene view takes its swap chain / surface when
    /// it mounts. The same view presented again only changes what it is called.
    private func mountSurface(_ view: UIView, kind: Int, id: Int, owner: UINodeNativeView? = nil) {
        pendingSurfaceRelease = false
        if surfaceView !== view {
            releaseSurface()
            surfaceView = view
            surfaceOwner = owner
            surfaceViewId = kind == DestKind.native ? id : nil
            view.removeFromSuperview()
            view.place(bounds)
            view.autoresizingMask = []
            insertSubview(view, at: 0)
            (view as? SceneView)?.createSwapChain()
        }
        surfaceKind = kind
        surfaceId = id
    }

    /// The surface leaves: a promoted native view goes back into its embedding node; a 3D scene's
    /// view lets its swap chain go (the frame stops presenting).
    private func releaseSurface() {
        pendingSurfaceRelease = false
        guard let view = surfaceView else { return }
        surfaceView = nil
        view.removeFromSuperview()
        (view as? SceneView)?.destroySwapChain()
        // The embedding node may have built its view only after the promotion (its paint came
        // later): resolve it now as well as at open.
        let owner = surfaceOwner ?? surfaceViewId.flatMap { UINodeNativeView.embedding(viewId: $0) }
        surfaceOwner = nil
        surfaceViewId = nil
        surfaceKind = DestKind.none
        surfaceId = 0
        owner?.readopt()
    }

    /// UIRootHost: the registerView instance `viewId` is the presented destination right now.
    public func isPromoted(viewId: Int) -> Bool { destKind == DestKind.native && destId == viewId && surfaceView != nil }

    /// The fullscreen video's view: a black backdrop under the player layer.
    private final class VideoSurfaceView: UIView {
        private let playerLayer: AVPlayerLayer
        init(layer: AVPlayerLayer) {
            playerLayer = layer
            super.init(frame: .zero)
            backgroundColor = .black
            self.layer.addSublayer(layer)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    /// The screen a back reveals, by the runtime's answer.
    private var revealedForBack: Int {
        switch Core.backTarget() {
        case .router(let revealed), .handler(let revealed): return revealed
        default: return 0
        }
    }

    // MARK: - the system's back swipe (SystemBackSwipeDelegate)

    /// What the runtime has said of the screen a swipe reveals.
    private enum Answer {
        case offered   // nothing is asked: the finger is down, or the pop ran back
        case asking    // the back chain is running: an openView naming the revealed screen is its answer
        case kept      // the chain ran and the screen that was shown stays
        case adopted   // the revealed screen was presented
        case left      // …and the runtime has dropped it since (the app navigated on)
    }
    private struct Swiped {
        let revealed: UINode
        var answer = Answer.offered
        /// The screen the revealed one replaced: it goes with the end of the pop, which is still
        /// moving it, not with the runtime's dropDest — that came at the release.
        var leaving: UIView?
    }

    /// Whether the system's swipe would reveal a screen now: the runtime names one (the router's
    /// pop, or the screen the current screen's own `onBack` handler would let pop — the handler
    /// answers at the release). A shown widget's handler, a non-screen destination, the router's
    /// root name nothing: no swipe.
    var canSystemBack: Bool {
        guard swiped == nil, currentScreen != nil else { return false }
        switch Core.backTarget() {
        case .router(let revealed), .handler(let revealed):
            return revealed != 0 && Nodes[revealed].map { $0 !== currentScreen } ?? false
        default: return false
        }
    }

    /// The swipe begins: a transition in flight lands (what the landing wrote reaches the views
    /// NOW — left for the frame's sync, the records would be applied over what the swipe does),
    /// and the revealed screen's view goes into the swipe's page, laid out at the viewport.
    public func backSwipeReveals(in page: UIView) -> Bool {
        guard canSystemBack else { return false }
        Core.settleTransitions()
        FrameBatcher.runTick()
        guard let revealed = Nodes[revealedForBack], revealed !== currentScreen else { return false }
        swiped = Swiped(revealed: revealed)
        let view = revealed.view
        page.backgroundColor = view.backgroundColor ?? backgroundColor
        view.place(bounds)
        page.addSubview(view)
        revealed.updateLayout()
        return true
    }

    /// The back is made: the chain the button runs. true = the runtime answered with the revealed
    /// screen (openScreen adopted it); false = a screen's own handler kept its screen, or
    /// presented something else.
    public func backSwipeReleased() -> Bool {
        guard swiped != nil else { return false }
        swiped?.answer = .asking
        Core.backCommitted()
        if swiped?.answer == .asking { swiped?.answer = .kept }
        return swiped?.answer == .adopted
    }

    /// The pop is over. Taken, the revealed screen's view comes in: as the presented screen, or —
    /// the app navigated on while the pop was landing — under the presented one, as the side that
    /// is leaving, until the runtime drops it.
    public func backSwipeLanded(taken: Bool) {
        guard let s = swiped else { return }
        swiped = nil
        // A background change the swipe held back (screenBackgroundChanged) lands now.
        if let current = currentScreen { applyScreenBackground(current) }
        // Not a screen that is presented again by now.
        if let leaving = s.leaving, leaving !== screenView { leaving.removeFromSuperview() }
        let view = s.revealed.view
        if view.superview === self { return }   // presented since, by a change of its own
        guard taken, s.answer == .adopted, !s.revealed.isRemoved else {
            view.removeFromSuperview()
            return
        }
        view.place(bounds)
        if let surface = surfaceView { insertSubview(view, aboveSubview: surface) } else { insertSubview(view, at: 0) }
        s.revealed.updateLayout()
    }

    @objc private func onDismissTap(_ g: UITapGestureRecognizer) {
        if g.state == .ended { keyboard.hideKeyboard() }
    }

    /// Nothing is the current destination. What was shown — the screen, the surface — stays
    /// mounted until the runtime drops it: it may be leaving with a transition.
    func closeDest() {
        destKind = DestKind.none
        destId = 0
        keyboard.dismissKeyboardForNavigation()
        leaveScreen()
        widgets.updateAttached()
    }

    // MARK: - widgets

    func widgetOpen(_ node: UINode, owner: WidgetOwner) {
        guard let widget = node as? UINodeWidget else { return }
        widgets.open(widget, owner: owner)
    }
    func widgetClose(_ node: UINode) { widgets.close(node) }
    /// The open widgets' roots, in open order.
    public var openWidgets: [UINode] { widgets.roots }

    /// The runtime freed a node: forget it wherever it is held.
    func nodeReleased(_ node: UINode) {
        keyboard.onRootReleased(node)
        if currentScreen === node { leaveScreen() }
        // …and a screen that was still leaving goes with its node
        if node is UINodeScreen, node.view.superview === self { node.view.removeFromSuperview() }
        if widgets.contains(node) { widgets.close(node) }
        if surfaceOwner === node { surfaceOwner = nil }
    }

    // MARK: - toasts

    /// HostUI.showToast: above the keyboard, queued.
    func showToast(_ message: String, durationMs: Int) {
        ToastView.show(message, durationMs: durationMs, in: self)
    }

    // MARK: - UIRootHost

    public var keyboardInset: CGFloat { keyboard.keyboardInset }
    public func onInputFocused(_ input: UINodeInput) { keyboard.onInputFocused(input) }
    public func onInputBlurred(_ input: UINodeInput) { keyboard.onInputBlurred(input) }
    public func hideKeyboard() { keyboard.hideKeyboard() }
    public func dismissKeyboardForNavigation() { keyboard.dismissKeyboardForNavigation() }
    public func updateAttachedWidgets() { widgets.updateAttached() }
    public var presentingViewController: UIViewController? {
        var r: UIResponder? = next
        while let cur = r {
            if let vc = cur as? UIViewController { return vc }
            r = cur.next
        }
        return nil
    }

    // MARK: - the scripted keyboard (the tests; no keyboard shows on a simulator without a window)

    /// The keyboard's overlap as a notification would report it: `inset` points over the bottom
    /// edge, 0 = hidden. The layout lands on the next tick.
    public func simulateKeyboard(inset: CGFloat) {
        keyboard.setKeyboardInset(inset, duration: 0, curve: [])
    }
    /// The root the keyboard shrinks right now, and by how much (0 = none).
    public var shrunkRoot: (node: UINode, overlap: CGFloat)? {
        keyboard.shrunkRoot.map { ($0, keyboard.shrunkOverlap) }
    }
    /// The scrollable carrying the keyboard's contentInset (native inset mode), if any.
    public var keyboardInsetScrollable: UINode? { keyboard.insetScrollable }

    // MARK: - the scripted pointer (the check runner; the desktop host's `tap X Y`)

    private var pointerTargets: [Int32: PointerTarget] = [:]

    /// A pointer went down at (x, y) in this view's space: the same hit-test a UITouch takes, then
    /// the target's own handlers.
    public func pointerDown(_ pointerId: Int32, x: CGFloat, y: CGFloat) {
        let p = CGPoint(x: x, y: y)
        var v = hitTest(p, with: nil)
        while let cur = v {
            if let target = cur as? PointerTarget {
                pointerTargets[pointerId] = target
                target.pointerDown(pointerId, at: p)
                return
            }
            v = cur.superview
        }
    }
    public func pointerMove(_ pointerId: Int32, x: CGFloat, y: CGFloat) {
        pointerTargets[pointerId]?.pointerMove(pointerId, to: CGPoint(x: x, y: y))
    }
    public func pointerUp(_ pointerId: Int32, x: CGFloat, y: CGFloat) {
        pointerTargets.removeValue(forKey: pointerId)?.pointerUp(pointerId, at: CGPoint(x: x, y: y))
    }
    public func pointerCancel(_ pointerId: Int32) {
        pointerTargets.removeValue(forKey: pointerId)?.pointerCancel(pointerId)
    }
}

extension LeCodesView: UIGestureRecognizerDelegate {
    /// The dismissal tap coexists with every scroll / pager / press gesture (it must steal none).
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === dismissTap || other === dismissTap
    }
    /// The dismissal tap only sees touches that land outside every control, while the keyboard is
    /// up and the focused input allows dismissal.
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        g === dismissTap ? keyboard.shouldDismiss(onTouchIn: touch.view) : true
    }
}
