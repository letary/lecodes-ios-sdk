// A SHELL: the viewer pinned to one project — an app `lecodes app init ios` generates, which runs
// the bundle it carries (App/Resources/app.js) offline and takes the project's newer bundles over
// the air. Everything a shell does is a public primitive of this SDK, assembled here; an app that
// embeds LeCodes as a library takes the pieces it wants (LeCodesEngine + LeCodesView in its own
// controller, `engine.run(code)` of a bundle it fetched itself, LeCodesUpdater on its own) and
// never needs this file. The generated code of a shell is a subclass of the controller below with
// `configure` filled in (the plugins, the AR kinds, the identity) — the CLI-owned LeCodesRuntime
// package; the app's own ViewController subclasses THAT and is empty until the app wants more.
import LeCodesCore
import UIKit

public enum LeCodesShell {
    /// The boot of a shell: the device language, the newest LOCAL bundle (`activeBundle` — where the
    /// state a store update left is migrated or cleared), the OTA check (before anything runs: a
    /// broken bundle can never block its own fix), then the bundle into the engine and the frame
    /// loop on. On the FIRST launch of this binary with OTA configured (no usable update state: a
    /// fresh install, or a store update that dropped the cache) the run waits for the check, at
    /// most `firstLaunchTimeout` seconds, never blocking the main thread: a download it stored runs
    /// at once; up to date, refused, failed (offline fails at once) or the timeout run the local
    /// bundle. Every later launch runs the local bundle at once and a download applies on the next
    /// one. `onReady` is called on the main queue right after the bundle runs (the shell controller
    /// takes its launch screen down from there). `embeddedAt` / `source` default to the app's
    /// `App/Resources/app.js` and Info.plist's `LeCodesUpdateURL` (LeCodesUpdater). False when there
    /// is no bundle to run (the shell was never synced) — nothing ran, `onReady` is never called.
    @discardableResult
    public static func boot(_ engine: LeCodesEngine, embeddedAt: URL? = nil, source: URL? = LeCodesUpdater.configuredURL,
                            firstLaunchTimeout: TimeInterval = 5, onReady: (() -> Void)? = nil) -> Bool {
        engine.setLanguage(Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en")
        return launch(embeddedAt: embeddedAt, source: source, firstLaunchTimeout: firstLaunchTimeout) { code in
            engine.run(code)
            engine.resume()
            onReady?()
        }
    }

    /// The decision of `boot` without the engine — boot hands its engine in as `run`, the tests
    /// their own. `run` is called exactly once: synchronously when nothing waits, else on the main
    /// queue by whichever comes first, the check's answer or the timeout (the other is a no-op: a
    /// late answer is only stored, for the next launch — it never touches the running world).
    /// `onCheck` hears the check's result on the main queue in either case. False = no embedded bundle.
    static func launch(embeddedAt: URL?, source: URL?, firstLaunchTimeout: TimeInterval,
                       onCheck: @escaping (LeCodesUpdater.UpdateResult) -> Void = { _ in },
                       run: @escaping (String) -> Void) -> Bool {
        // The local bundle FIRST: it migrates (or clears) the state of a store update, so the check
        // below sees a usable state and sends its validators.
        guard let local = LeCodesUpdater.activeBundle(embeddedAt: embeddedAt, source: source) else { return false }
        let configured = (source ?? LeCodesUpdater.configuredURL) != nil
        guard configured, !LeCodesUpdater.hasUsableState(embeddedAt: embeddedAt, source: source) else {
            LeCodesUpdater.checkForUpdate(url: source, embeddedAt: embeddedAt) { result in
                DispatchQueue.main.async { onCheck(result) }
            }
            run(local)
            return true
        }

        // The first launch of this binary: the check's answer or the timeout, whichever is first.
        let race = FirstLaunchRace()
        let timeout = DispatchWorkItem {
            guard race.take() else { return }
            print("LeCodes: first launch — no answer from the update source in \(firstLaunchTimeout) s, the local bundle runs")
            run(local)
        }
        race.timeout = timeout
        // Queued BEFORE the check starts, so a timeout of 0 always runs first.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, firstLaunchTimeout), execute: timeout)
        LeCodesUpdater.checkForUpdate(url: source, embeddedAt: embeddedAt) { result in
            DispatchQueue.main.async {
                if race.take() {
                    if result == .updated, let fresh = LeCodesUpdater.activeBundle(embeddedAt: embeddedAt, source: source) {
                        print("LeCodes: first launch — the downloaded bundle runs now")
                        run(fresh)
                    } else {
                        run(local)
                    }
                }
                onCheck(result)
            }
        }
        return true
    }
}

/// The first-launch race (the check's answer, the timeout): the first `take()` wins and cancels the
/// timeout, every later one is false. Touched on the main queue only, hence unchecked.
private final class FirstLaunchRace: @unchecked Sendable {
    var timeout: DispatchWorkItem?
    private var taken = false
    func take() -> Bool {
        if taken { return false }
        taken = true
        timeout?.cancel()
        timeout = nil
        return true
    }
}

/// The controller of a shell: a LeCodesViewController that boots itself when its view loads —
/// `configure(_:)` first (the generated runtime registers the plugins there, before the bundle's
/// synchronous top level asks `isSupported`), then LeCodesShell.boot. Until the bundle has drawn its
/// first frame it holds the app's launch screen over its container (the storyboard
/// `UILaunchStoryboardName` of Info.plist names, instantiated; none → nothing), so what the system
/// showed at launch stays through the first-launch wait with no black frame between it and the app.
/// The lifecycle (the frame loop paused in the background) is the engine's own (AppEvents); the
/// scene delegate does nothing.
open class LeCodesShellViewController: LeCodesViewController {
    public override init(engine: LeCodesEngine = LeCodesEngine()) {
        super.init(engine: engine)
    }

    /// Before the bundle runs: the plugins (`XPlugin.register(in:)`), the AR controller kinds, the
    /// world identity (`engine.bootProjectUuid`). The generated runtime's override; empty here.
    open func configure(_ engine: LeCodesEngine) {}

    /// The bundle the shell carries; nil = `App/Resources/app.js`.
    open var embeddedBundle: URL? { nil }
    /// Where newer bundles come from; the default is Info.plist's `LeCodesUpdateURL`.
    open var updateSource: URL? { LeCodesUpdater.configuredURL }
    /// How long the first launch of this binary waits for the update check (LeCodesShell.boot).
    open var firstLaunchTimeout: TimeInterval { 5 }

    /// The launch screen held over the container until the bundle's first frame.
    private var launchScreen: UIViewController?

    open override func viewDidLoad() {
        super.viewDidLoad()
        mountLaunchScreen()
        configure(engine)
        if !LeCodesShell.boot(engine, embeddedAt: embeddedBundle, source: updateSource, firstLaunchTimeout: firstLaunchTimeout,
                              onReady: { [weak self] in self?.dropLaunchScreen() }) {
            print("LeCodes: no bundled app.js — run `lecodes app sync`")
        }
    }

    /// The launch storyboard's initial controller over the container, which takes its colour
    /// instead of black. The app root inside keeps its own (black, what a screen without a
    /// background shows); the overlay stays until the root has drawn (dropLaunchScreen).
    private func mountLaunchScreen() {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String, !name.isEmpty,
              Bundle.main.path(forResource: name, ofType: "storyboardc") != nil,   // UIStoryboard(name:) raises on a missing one
              let screen = UIStoryboard(name: name, bundle: .main).instantiateInitialViewController() else { return }
        if let color = screen.view.backgroundColor { view.backgroundColor = color }
        addChild(screen)
        screen.view.frame = view.bounds
        screen.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen.view)
        screen.didMove(toParent: self)
        launchScreen = screen
    }

    /// The bundle runs: the launch screen goes two display frames later, once the view is in a
    /// window — by then the engine's own display link has ticked the bundle's first frame onto the
    /// screen, so the root's black is never shown between the two.
    private func dropLaunchScreen() {
        guard let screen = launchScreen else { return }
        launchScreen = nil
        AfterFrames.start(2, of: view) {
            screen.willMove(toParent: nil)
            screen.view.removeFromSuperview()
            screen.removeFromParent()
        }
    }
}

/// `done` after `frames` display frames of a view that is in a window (or at once when the view is
/// gone). The display link holds this object until it is invalidated.
private final class AfterFrames: NSObject {
    private var left: Int
    private weak var view: UIView?
    private let done: () -> Void
    private var link: CADisplayLink?

    static func start(_ frames: Int, of view: UIView, done: @escaping () -> Void) {
        let waiter = AfterFrames(frames, view, done)
        let link = CADisplayLink(target: waiter, selector: #selector(step))
        waiter.link = link
        link.add(to: .main, forMode: .common)
    }

    private init(_ frames: Int, _ view: UIView, _ done: @escaping () -> Void) {
        self.left = frames
        self.view = view
        self.done = done
    }

    @objc private func step() {
        if let view, view.window == nil { return }
        left -= 1
        guard left <= 0 || view == nil else { return }
        link?.invalidate()
        link = nil
        done()
    }
}
