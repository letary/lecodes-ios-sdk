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
    /// The boot of a shell: the device language, the OTA check (first — a broken bundle can never
    /// block its own fix), then the newest local bundle into the engine and the frame loop on.
    /// `embeddedAt` / `source` default to the app's `App/Resources/app.js` and Info.plist's
    /// `LeCodesUpdateURL` (LeCodesUpdater). False when there is no bundle to run (the shell was
    /// never synced) — nothing ran.
    @discardableResult
    public static func boot(_ engine: LeCodesEngine, embeddedAt: URL? = nil, source: URL? = LeCodesUpdater.configuredURL) -> Bool {
        engine.setLanguage(Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en")
        LeCodesUpdater.checkForUpdate(url: source, embeddedAt: embeddedAt)
        guard let code = LeCodesUpdater.activeBundle(embeddedAt: embeddedAt, source: source) else { return false }
        engine.run(code)
        engine.resume()
        return true
    }
}

/// The controller of a shell: a LeCodesViewController that boots itself when its view loads —
/// `configure(_:)` first (the generated runtime registers the plugins there, before the bundle's
/// synchronous top level asks `isSupported`), then LeCodesShell.boot. The lifecycle (the frame loop
/// paused in the background) is the engine's own (AppEvents); the scene delegate does nothing.
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

    open override func viewDidLoad() {
        super.viewDidLoad()
        configure(engine)
        if !LeCodesShell.boot(engine, embeddedAt: embeddedBundle, source: updateSource) {
            print("LeCodes: no bundled app.js — run `lecodes app sync`")
        }
    }
}
