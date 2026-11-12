// A SHELL: the viewer pinned to one project — an app `lecodes app init ios` generates, which runs
// the bundle it carries (App/Resources/app.js) offline and takes the project's newer bundles over
// the air. Everything a shell does is a public primitive of this SDK, assembled here; an app that
// embeds LeCodes as a library takes the pieces it wants (LeCodesEngine + LeCodesView in its own
// controller, `engine.run(code)` of a bundle it fetched itself, LeCodesUpdater on its own) and
// never needs this file. The generated code of a shell is a subclass of the controller below with
// `configure` filled in (the plugins, the AR kinds, the identity) — the CLI-owned LeCodesRuntime
// package; the app's own ViewController subclasses THAT and is empty until the app wants more.
import LeCodesCore
import LeCodesUIKit
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
    /// one. `onReady` is called on the main queue right after the bundle runs. `onSplashDrop` is
    /// called on the main queue when the launch screen may go (the shell controller takes it down
    /// from there): right after the bundle runs too — unless the bundle's top level called
    /// `app.splash.hold()`, then at `app.splash.hide()`, at most `splashHoldTimeout` seconds later
    /// (SplashHold). `embeddedAt` / `source` default to the app's
    /// `App/Resources/app.js` and `LeCodesUpdater.sourceURL` (the source the app set for itself, else
    /// Info.plist's `LeCodesUpdateURL`). False when there
    /// is no bundle to run (the shell was never synced) — nothing ran, neither callback is called.
    @discardableResult
    public static func boot(_ engine: LeCodesEngine, embeddedAt: URL? = nil, source: URL? = LeCodesUpdater.sourceURL,
                            firstLaunchTimeout: TimeInterval = 5, onReady: (() -> Void)? = nil,
                            onSplashDrop: (() -> Void)? = nil) -> Bool {
        LeCodesUpdater.isShell = true
        // the files this build carries, for a bundle that names them by url (one taken over the air)
        EmbeddedAssets.attach { [weak engine] name in engine?.onFetchLocal(name) }
        engine.setLanguage(Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en")
        let hold = SplashHold()
        splash = hold
        return launch(embeddedAt: embeddedAt, source: source, firstLaunchTimeout: firstLaunchTimeout) { code in
            hold.run({
                engine.run(withEngineBoot(code))
                engine.resume()
            }, drop: { onSplashDrop?() })
            onReady?()
        }
    }

    /// What the launcher of a viewer does before it runs a project (hosts/mobile-init): a bundle
    /// whose header has no `// gl:` line uses the 3D engine from its first line and expects it UP
    /// — `// gl: disable` has none, `// gl: defer` calls createEngine itself. A shell has no
    /// launcher, so the call is put in front of the bundle's own code: on the line where it starts
    /// (the header above stays whole, no line of the bundle moves). Without it the first
    /// `_creator.create…` of such a bundle read a null engine and the app died (an AR screen, 2026-11-12).
    /// A variant without the engine has no `_creator.createEngine`: the call is not made.
    static func withEngineBoot(_ code: String) -> String {
        var at = code.startIndex
        var compiled = false
        while at < code.endIndex, code[at...].hasPrefix("//") {
            if code[at...].hasPrefix("// gl:") { return code }
            if code[at...].hasPrefix("// sdk:") { compiled = true }
            guard let end = code[at...].firstIndex(of: "\n") else { at = code.endIndex; break }
            at = code.index(after: end)
        }
        guard compiled else { return code }   // not a compiled bundle: nothing is known of it
        return String(code[..<at]) + engineBoot + String(code[at...])
    }
    static let engineBoot =
        "try{typeof _creator!==\"undefined\"&&_creator&&_creator.createEngine&&_creator.createEngine()}catch(e){console.error(\"createEngine: \"+e)};"

    /// The splash of the launch `boot` holds — what `_creatorApp.holdSplash` / `hideSplash` reach
    /// (host/AppHost). Nil in an app that did not boot as a shell: nothing to hold there. Main
    /// thread only, hence unchecked.
    nonisolated(unsafe) static var splash: SplashHold?

    /// How long a bundle may keep the launch screen after its top level returned (app.splash.hold).
    static let splashHoldTimeout: TimeInterval = 5

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
        let configured = (source ?? LeCodesUpdater.sourceURL) != nil
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

/// The launch screen past the bundle's start — the twin of Android's LeCodesShell.SplashHold: `run`
/// evaluates the bundle and then calls `drop` (the launch screen goes) — at once, or, when the
/// bundle called `hold()` during that evaluation, at `hide()` or after `timeout` seconds, whichever
/// is first. `drop` is called exactly once. `hold()` is honoured only while the launch screen is
/// still up (during the evaluation, or while an earlier hold is open): a later call holds nothing
/// and says so. Touched on the main queue only, hence unchecked.
final class SplashHold: @unchecked Sendable {
    private let timeout: TimeInterval
    private var running = false
    private var held = false
    private var drop: (() -> Void)?
    private var limit: DispatchWorkItem?

    init(timeout: TimeInterval = LeCodesShell.splashHoldTimeout) { self.timeout = timeout }

    func run(_ bundle: () -> Void, drop: @escaping () -> Void) {
        running = true
        held = false
        bundle()
        running = false
        guard held else { drop(); return }
        self.drop = drop
        let limit = DispatchWorkItem { [weak self] in
            guard let self, self.drop != nil else { return }
            print("LeCodes: app.splash.hold — no app.splash.hide() in \(self.timeout) s, the launch screen goes")
            self.hide()
        }
        self.limit = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, timeout), execute: limit)
    }

    func hold() -> Bool {
        guard running || drop != nil else { return false }
        held = true
        return true
    }

    func hide() {
        held = false
        guard let go = drop else { return }
        drop = nil
        limit?.cancel()
        limit = nil
        go()
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
/// synchronous top level asks `supported`), then LeCodesShell.boot. Until the bundle has drawn its
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
    /// Where newer bundles come from; the default is the source the app set for itself
    /// (`app.update.setSource`), else Info.plist's `LeCodesUpdateURL`.
    open var updateSource: URL? { LeCodesUpdater.sourceURL }
    /// How long the first launch of this binary waits for the update check (LeCodesShell.boot).
    open var firstLaunchTimeout: TimeInterval { 5 }

    /// The launch screen held over the container until the bundle's first frame.
    private var launchScreen: UIViewController?
    /// Its animation, when app.json sets one.
    private var splashAnimation: SplashAnimation?

    open override func viewDidLoad() {
        super.viewDidLoad()
        mountLaunchScreen()
        configure(engine)
        if !LeCodesShell.boot(engine, embeddedAt: embeddedBundle, source: updateSource, firstLaunchTimeout: firstLaunchTimeout,
                              onSplashDrop: { [weak self] in self?.dropLaunchScreen() }) {
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
        screen.view.place(view.bounds)
        screen.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen.view)
        screen.didMove(toParent: self)
        launchScreen = screen
        // app.json "splash.animation": the storyboard's image view moves from the still picture
        // the system showed, once the view is on screen (an animation of a layer outside a window
        // does not run).
        if let animation = SplashAnimation.load(), let image = screen.view.subviews.first(where: { $0 is UIImageView }) {
            splashAnimation = animation
            AfterFrames.start(1, of: view) { animation.play(on: image) }
        }
    }

    /// The bundle runs (and, when it held the launch screen with app.splash.hold, has let it go):
    /// the launch screen goes two display frames later, once the view is in a
    /// window — by then the engine's own display link has ticked the bundle's first frame onto the
    /// screen, so the root's black is never shown between the two.
    /// An animated launch screen (app.json "splash.animation") stays for one whole pass of its
    /// animation at least, then fades away over the app.
    private func dropLaunchScreen() {
        guard let screen = launchScreen else { return }
        launchScreen = nil
        let animation = splashAnimation
        splashAnimation = nil
        let remove = {
            screen.willMove(toParent: nil)
            screen.view.removeFromSuperview()
            screen.removeFromParent()
        }
        AfterFrames.start(2, of: view) {
            guard let animation else { remove(); return }
            animation.whenPlayed {
                UIView.animate(withDuration: animation.fadeOut / 1000, animations: { screen.view.alpha = 0 },
                               completion: { _ in remove() })
            }
        }
    }
}

/// app.json "splash.animation" as `lecodes app sync` resolved it — the data asset
/// LeCodesSplashAnimation (tools/cli/src/commands/app/splash.ts; the Android shell reads the same
/// file): a track per animated property of the launch screen's image, each a keyframe animation
/// Core Animation plays as it is — in the render server, so it keeps moving while the bundle
/// evaluates on the main thread. Main thread only.
final class SplashAnimation: Decodable {
    struct Track: Decodable {
        /// "scale" | "opacity" | "rotate" (degrees) | "x" | "y" (pt from the centre).
        let property: String
        /// 0…1, a value per time, a cubic-bezier [x1, y1, x2, y2] per segment.
        let times: [Double]
        let values: [Double]
        let easings: [[Float]]
    }
    /// One pass and the fade the launch screen leaves with, ms.
    let duration: Double
    let fadeOut: Double
    let tracks: [Track]

    private enum CodingKeys: String, CodingKey { case duration, fadeOut, tracks }

    private var endsAt: CFTimeInterval?
    private var played: (() -> Void)?

    /// The asset of the app, nil when app.json sets no animation (or the file is not one).
    static func load() -> SplashAnimation? {
        guard let asset = NSDataAsset(name: "LeCodesSplashAnimation") else { return nil }
        guard let animation = try? JSONDecoder().decode(SplashAnimation.self, from: asset.data), animation.duration > 0 else {
            print("LeCodes: the LeCodesSplashAnimation asset is not an animation — run `lecodes app sync`")
            return nil
        }
        return animation
    }

    private static let keyPaths = [
        "scale": "transform.scale", "opacity": "opacity", "rotate": "transform.rotation.z",
        "x": "transform.translation.x", "y": "transform.translation.y",
    ]

    /// Start the one pass on the image view. The view is left at the LAST keyframe (its model
    /// values), which is what shows when the pass is over — or at once, should the system drop
    /// the animation (the app went to the background).
    func play(on view: UIView) {
        var last: [String: Double] = [:]
        let animations: [CAAnimation] = tracks.compactMap { track in
            guard let keyPath = Self.keyPaths[track.property], track.values.count >= 2, track.times.count == track.values.count,
                  track.easings.count == track.values.count - 1, track.easings.allSatisfy({ $0.count == 4 }) else { return nil }
            let unit = track.property == "rotate" ? Double.pi / 180 : 1
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = track.values.map { NSNumber(value: $0 * unit) }
            animation.keyTimes = track.times.map { NSNumber(value: $0) }
            animation.timingFunctions = track.easings.map { CAMediaTimingFunction(controlPoints: $0[0], $0[1], $0[2], $0[3]) }
            last[track.property] = track.values[track.values.count - 1]
            return animation
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration / 1000
        view.alpha = CGFloat(last["opacity"] ?? 1)   // the storyboard hides an image the first frame hides
        view.transform = CGAffineTransform(translationX: CGFloat(last["x"] ?? 0), y: CGFloat(last["y"] ?? 0))
            .rotated(by: CGFloat((last["rotate"] ?? 0) * .pi / 180))
            .scaledBy(x: CGFloat(last["scale"] ?? 1), y: CGFloat(last["scale"] ?? 1))
        view.layer.add(group, forKey: "lecodes.splash")
        endsAt = CACurrentMediaTime() + group.duration
        if let played { self.played = nil; whenPlayed(played) }
    }

    /// `done` once the pass is over — at once when it already is.
    func whenPlayed(_ done: @escaping () -> Void) {
        guard let endsAt else { played = done; return }   // not started yet: `play` passes it on
        let left = endsAt - CACurrentMediaTime()
        if left <= 0 { done() } else { DispatchQueue.main.asyncAfter(deadline: .now() + left, execute: done) }
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
