// The view controller an app mounts the engine with — the twin of the old SDK's
// LeCodesViewController, cut to what the new host needs: the engine, a LeCodesView as the
// controller's view (the app root: destinations, widgets, the keyboard, the toasts all live
// there), the interface-orientation lock (app.setOrientation → OrientationLock, re-read by UIKit
// through supportedInterfaceOrientations), the launch argument of `lecodes dev --ios`, and
// `start(initialJs:)` — the boot of the JS world, which must be the LAST step of scene setup:
// the launcher reads app.launchUrl and resolves the registered plugin factories at synchronous
// top level. A viewer subclasses it to register its plugins (postInit) and to show what it wants
// over the root (the uncaught-error overlay of the viewer app is one).
import LeCodesCore
import LeCodesUIKit
import UIKit

open class LeCodesViewController: UIViewController {
    public let engine: LeCodesEngine
    /// The app root (created with the controller, mounted as its view).
    public let rootView: LeCodesView

    public init(engine: LeCodesEngine) {
        self.engine = engine
        self.rootView = LeCodesView(engine: engine)
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { nil }

    /// The system's back swipe over the root (the renderer's SystemBackSwipe): what this
    /// controller mounts is the swipe's view, the root inside it.
    private lazy var backSwipe = SystemBackSwipe(stage: rootView, delegate: rootView)

    open override func loadView() {
        let container = UIView()
        container.backgroundColor = .black
        view = container
        rootView.backSwipe = backSwipe
        rootView.onStatusBarStyle = { [weak self] in self?.setNeedsStatusBarAppearanceUpdate() }
        let stage = backSwipe.view
        stage.place(container.bounds)
        stage.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(stage)
    }

    /// The root's word (LeCodesView.statusBarStyle): by the presented screen's background.
    open override var preferredStatusBarStyle: UIStatusBarStyle { rootView.statusBarStyle }

    /// app.setOrientation: a locked world imposes its mask; `.auto` keeps UIKit's default (the
    /// Info.plist list). Re-read by UIKit after OrientationLock.apply invalidates it.
    open override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        OrientationLock.current.mask ?? super.supportedInterfaceOrientations
    }

    /// Boot the JS world with the launcher bundle (initial.js). Everything the bundle observes at
    /// synchronous top level — the launch URL (setLaunchUrl / emitUrl), the registries — must be
    /// in place; the frame loop starts with it.
    open func start(initialJs code: String) {
        engine.run(code)
        engine.resume()
    }

    /// `lecodes dev --ios` launches the app with `--lecodes-url <url>` (the iOS twin of Android's
    /// VIEW intent: the simulator has no universal links, the CLI has no `adb reverse`): the dev
    /// bundle's url, seeded as the launch URL BEFORE the world boots so initial.js opens it like a
    /// scanned QR. nil when the app was launched normally.
    public static var launchArgumentUrl: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--lecodes-url"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
