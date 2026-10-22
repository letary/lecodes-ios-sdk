// The iOS host of the runtime — the twin of hosts/android's LecodesEngine. Builds the host
// contract's tables (HostServices of LeCodesCore, the same model as creator-pkg/host.gen.h; one
// class per table in host/) over the services (services/), hands them to the runtime before
// initJS, and drives the frame loop (CADisplayLink → Core.runTick). The runtime calls the tables
// from the JS thread, which is the main thread here.
//
// What stays on this class: the lifecycle (resume / pause / dispose), world control, the
// embedder's hooks (fetchLocal, the registries: callbacks, services, native views), the gl facade
// a plugin's half drives the 3D engine through (`gl`, scene/GL.swift), the log sink. The UI
// renderer (renderers/uikit) arrives through the `ui` table,
// the scene hosts through `gl` / `scene2d` / `canvas` (GLHost / Scene2dHost / CreatorCanvas by
// default, for the features the linked engine has); HeadlessUI + HeadlessGL are the engine-only
// host of the tests and the checks runner.
import Foundation
import UIKit
import LeCodesCore
import LeCodesUIKit

public final class LeCodesEngine {

    // MARK: - The embedder's hooks

    /// A local asset by name (HostFetch.local): the app resolves it first (its own bundle,
    /// a project folder). The default reads Bundle.main by file name, like the old viewer.
    public var onFetchLocal: (String) -> Data? = { path in
        let ext = (path as NSString).pathExtension
        let name = (path as NSString).deletingPathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext.isEmpty ? nil : ext) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The registerView registry (`NativeView(name)` elements): the renderer mounts its instances.
    public let nativeViews = NativeViews()
    /// The registerService registry (typed plugins over the service channel).
    let services = Services()
    /// The OS permissions (camera, microphone, location; a plugin registers the kind it brings):
    /// what the SDK's `permissions` and a plugin's `@permission` glue ask. services/Permissions.swift.
    public let permissions = Permissions()
    /// The gl facade: what a plugin's half drives the 3D engine through — the matrices of the
    /// entities the app handed it, a scene's projection and background, external textures, a hook
    /// before each frame, a pixel readback (scene/GL.swift). Every call a no-op without the engine.
    public let gl: GL

    /// Register a platform-view capability the SDK opens / embeds via `NativeView(name)`.
    /// `version` = the contract version the half was generated from: a generated registration says
    /// it, one written by hand is version 1.
    public func registerView(_ name: String, version: Int32 = 1, _ factory: @escaping NativeViewFactory) { nativeViews.register(name, version: version, factory) }
    /// Register a headless service capability (the UI-less sibling of registerView).
    public func registerService(_ name: String, version: Int32 = 1, _ factory: @escaping ServiceFactory) { services.register(name, version: version, factory) }
    /// A host-provided JS method (`registerCallback` of the runtime): a synchronous JS → Swift call.
    public func registerCallback(_ path: String, argsCount: Int, _ fn: @escaping ([LeScalar]) -> LeScalar) {
        Core.registerCallback(path, argsCount: argsCount, fn)
    }
    /// Store bytes the app produced (a camera shot, a generated file) and get their buffer id.
    public func addBuffer(_ data: Data) -> Int32 { Buffers.add(data) }

    /// Every runtime log line (console.* and the runtime's own) — nil restores stdout.
    public var onLog: ((LogLevel, String) -> Void)? {
        didSet {
            guard let onLog else { Core.setLogSink(nil); return }
            Core.setLogSink { level, line in onLog(LogLevel(rawValue: level) ?? .debug, line) }
        }
    }
    public enum LogLevel: Int { case debug = 0, info = 1, warn = 2, error = 3 }

    // MARK: - The host tables

    let app: AppHost
    let device: DeviceHost
    let fetch: FetchHost
    let files: FilesHost
    let storage: StorageHost
    let socket: SocketHost
    let service: ServiceHost
    let input: InputHost
    let media: MediaHost
    /// The UI renderer over the contract (renderers/uikit's HostUIRenderer, or HeadlessUI).
    public let ui: HostUI
    /// The renderer's seam into this host (nil with HeadlessUI).
    private let rendererServices: HostRendererServices?
    /// The scene hosts this engine built (nil when the caller handed its own table, or the linked
    /// engine has no such feature — Engine.features).
    let glHost: GLHost?
    let scene2dHost: Scene2dHost?
    /// The linked engine renders 3D (the media textures are pumped, the scene view prepared).
    public let hasGL: Bool
    /// The root view the renderer's views are mounted under (LeCodesView sets it); nil = nothing
    /// is shown, the runtime still lays out.
    public internal(set) weak var rootView: LeCodesView? {
        didSet { gl.stage = rootView }   // the viewport's rotation: the interface orientation of its window
    }

    let appEvents = AppEvents()
    let localFiles = LocalFiles()
    /// device.statsOverlay: the host's own line of frame numbers (StatsOverlay.swift).
    lazy var statsOverlay = StatsOverlay(engine: self)

    /// The engine boots ONCE per process (the runtime is process-wide): the tables are handed over
    /// and initJS runs here. `ui` nil = the UI renderer (renderers/uikit over this host's
    /// HostRendererServices; a LeCodesView presents it), else the table given (HeadlessUI for an
    /// embedder that shows nothing); `gl` / `scene2d` / `canvas` the scene hosts of a variant that
    /// has them (nil = the runtime skips the feature). `headless` = the engine-only 3D: Filament on
    /// its NOOP backend with HeadlessGL's swap chain (the tests, the checks runner).
    public init(ui: HostUI? = nil, canvas: HostCanvas? = nil, gl: HostGL? = nil, scene2d: HostScene2d? = nil, headless: Bool = false) {
        var canvas = canvas
        if let ui {
            self.ui = ui
            rendererServices = nil
        } else {
            let services = HostRendererServices()
            rendererServices = services
            self.ui = HostUIRenderer(services: services)
            // The renderer's painter host: canvas surfaces (the AnyCanvas painter over CoreGraphics)
            // and the SVG image nodes share it. An engine-only embedder has none (nil = every canvas
            // op a no-op, the contract's rule).
            if canvas == nil { canvas = CreatorCanvas.shared }
        }
        // The scene hosts, for the features the linked engine has (a `core` variant hands neither
        // over: the runtime skips the feature). Headless = the engine-only 3D (Filament on its NOOP
        // backend behind HeadlessGL); the 2D engine runs on Metal either way — the simulator has it.
        let features = Engine.features
        var gl = gl
        var scene2d = scene2d
        hasGL = features.contains("gl")
        self.gl = GL(hasEngine: hasGL)
        if headless {
            Core.setHeadlessBackend(true)
            if gl == nil { gl = HeadlessGL() }
            glHost = nil
        } else if gl == nil, hasGL {
            let host = GLHost()
            glHost = host
            gl = host
        } else {
            glHost = nil
        }
        if scene2d == nil, features.contains("2d") {
            let host = Scene2dHost()
            scene2dHost = host
            scene2d = host
        } else {
            scene2dHost = nil
        }
        app = AppHost()
        device = DeviceHost()
        fetch = FetchHost()
        files = FilesHost()
        storage = StorageHost()
        socket = SocketHost()
        service = ServiceHost()
        input = InputHost()
        media = MediaHost()
        media.players.gl = self.gl
        app.engine = self
        device.engine = self
        fetch.engine = self
        files.engine = self
        service.engine = self
        input.engine = self
        glHost?.engine = self
        (gl as? HeadlessGL)?.engine = self
        scene2dHost?.engine = self

        // The host contract, BEFORE initJS (the runtime validates every required table and slot and
        // aborts naming a missing one). `files` is present: the app OWNS its sandbox container, so
        // the SDK `files` global works there (relative paths land in Application Support).
        Core.setHostServices(HostServices(
            gl: gl, scene2d: scene2d, ui: self.ui, canvas: canvas,
            app: app, device: device, fetch: fetch, files: files, storage: storage,
            socket: socket, service: service, input: input, media: media))
        Core.initJS()
        // Without a renderer text measures 0×0 (yoga needs a function before the first layout —
        // the engine-only host answers like the windowless server); the renderer installed its own.
        if rendererServices == nil { Core.setMeasureFunc { _, _, _, _, _, _ in 0 } }

        rendererServices?.engine = self
        // UIImage(canvas) live repaint: Canvas.update() re-rasterizes the surface in place and then
        // feature-detects this hook; registering it is what tells the SDK the host can repaint an
        // on-screen image node without a `src` round-trip.
        if rendererServices != nil {
            Core.registerCallback("_creatorTree.refreshCanvasSurface", argsCount: 1) { args in
                switch args.first {
                case .int(let id)?: CanvasSurfaces.refresh(id)
                case .double(let id)?: CanvasSurfaces.refresh(Int32(id))
                default: break
                }
                return .null
            }
        }
        appEvents.engine = self
        appEvents.start()
    }

    // MARK: - Language / run

    public private(set) var language: String = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en" {
        didSet { Core.setLanguage(language) }
    }
    public func setLanguage(_ lang: String) { language = lang }

    /// Boot the app world (the viewer's launcher, a shell's bundled app.js). Everything the bundle
    /// can observe at synchronous top level (the launch URL, the registries) must be in place.
    public func run(_ code: String) {
        // A new project world restarts the SDK's viewIds — drop the objects those ids named, or the
        // next world inherits a previous project's live camera view.
        nativeViews.destroyAll()
        Core.run(code)
    }

    // MARK: - The frame

    private var displayLink: CADisplayLink?
    /// The clock the ticks carry — ms, monotonic, from the first tick.
    private let clockStart = ProcessInfo.processInfo.systemUptime

    /// One frame: the runtime's tick (timers, animations, the dispatch drain, JS jobs, the 3D frame
    /// when a scene is open). The display link calls it; the tests and the checks runner call it
    /// with their own clock.
    public func tick(nowMs: Int64? = nil) {
        let now = nowMs ?? Int64((ProcessInfo.processInfo.systemUptime - clockStart) * 1000)
        // device.statsOverlay: this tick's own time is its "cpu" (two clock reads, only while on).
        let stats = statsOverlay.enabled
        let start = stats ? ProcessInfo.processInfo.systemUptime : 0
        defer { if stats { statsOverlay.frame(start: start, end: ProcessInfo.processInfo.systemUptime) } }
        let rendered = rendererServices != nil
        // Everything that MUTATES the scene runs before the runtime's frame (Filament commits the
        // surface material instances inside beginFrame): the video frames into their textures, the
        // scene view's drawable at the scene's render scale.
        if hasGL {
            rootView?.sceneView?.prepareFrame()   // first: a body reads this frame's viewport (gl.viewport)
            gl.frame()   // the plugins' bodies (a camera frame, a pose): before the tick, so what they write is this frame's
            media.players.updateTextures()
        }
        // The renderer's frame around the runtime's: first whatever was queued since the last frame
        // (input, background results), then the mutations this tick produced, so a node added or
        // re-styled this frame is measured and laid out before it is drawn (a no-op when idle).
        if rendered { FrameBatcher.runTick() }
        Core.runTick(now)
        if rendered { FrameBatcher.runTick() }
        // creator-2d after the JS frame: the presented scene into its view, the UIImage(scene2d)
        // nodes into theirs (a cheap no-op for a UI / 3D project with none).
        scene2dHost?.frame(nowMs: now)
        onFrame?()
    }
    /// The renderer's per-frame hook (after runTick: the layout batch, the paint sync, the 2D frame).
    public var onFrame: (() -> Void)?

    /// Start the frame loop (the app is in the foreground).
    public func resume() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
        applyFrameRate(link)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// device.setFrameRate: the cap on the display link, 0 = the display's own rate. Host state — it
    /// stays through a project swap and across pause / resume (the link is made anew on each resume).
    public private(set) var frameRateCap: Double = 0
    public func setFrameRate(_ fps: Double) {
        frameRateCap = fps > 0 && fps.isFinite ? fps : 0
        if let link = displayLink { applyFrameRate(link) }
    }
    /// A fixed range at the cap: iOS shows the nearest rate the panel has (60 on a 120 Hz ProMotion =
    /// every second refresh), the tick — and the 3D frame inside it — comes at that rate. No Info.plist
    /// key is needed at or under 60; above it an iPhone wants the embedding app's
    /// CADisableMinimumFrameDurationOnPhone (renderers/uikit LayerTween.swift has the probe).
    private func applyFrameRate(_ link: CADisplayLink) {
        let f = Float(frameRateCap)
        link.preferredFrameRateRange = f > 0 ? CAFrameRateRange(minimum: f, maximum: f, preferred: f) : .default
    }
    /// device.displayRefreshRate: the fastest rate the screen offers the app — 120 on ProMotion, but an
    /// iPhone's display link stays at 60 unless the embedding app's Info.plist lifts the floor
    /// (CADisableMinimumFrameDurationOnPhone), and then that is what a cap can reach.
    static func displayRefreshRate() -> Double {
        let max = UIScreen.main.maximumFramesPerSecond
        if max > 60, UIDevice.current.userInterfaceIdiom == .phone,
           (Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool) != true {
            return 60
        }
        return Double(max)
    }
    /// Stop the frame loop. "pause" is delivered by AppEvents BEFORE this, with one explicit tick,
    /// so the app hears it — after the link stops nothing pumps the JS world.
    public func pause() {
        displayLink?.invalidate()
        displayLink = nil
    }
    @objc private func onDisplayLink() { tick() }

    // MARK: - App lifecycle & environment

    /// "active" | "background" — HostApp.state.
    public var appState: String { appEvents.state }
    /// The keyboard's raw overlap with the viewport in LOGICAL px — HostInput.keyboardHeight. The
    /// view layer writes it BEFORE Core.emitKeyboardEvent, so a handler reading the pull agrees.
    public var keyboardHeight: Float = 0
    /// device.setPreciseTouch (the 2D pointer path replays coalesced touches when set).
    public var preciseTouch = false

    /// Warm deep link: the pull first, then the "url" event (the ABI's ordering rule).
    public func emitUrl(_ url: String) {
        Core.setLaunchUrl(url)
        Core.emitAppEvent("url", data: url)
    }
    /// Cold-start launch-URL seed — BEFORE run(). nil clears.
    public func setLaunchUrl(_ url: String?) { Core.setLaunchUrl(url) }
    /// The system back gesture / a host back button: true when the runtime consumed it.
    public func onBackPressed() -> Bool { Core.onBackPressed() }

    // MARK: - World control (docs/push-plan.md decision 9)

    /// The launcher-family uuids whose worlds may declare identity for the worlds they run.
    public var trustedLaunchers: Set<String> = [] {
        didSet { Core.setTrustedLaunchers(Array(trustedLaunchers)) }
    }
    /// Boot-world identity for standalone shells; the viewer leaves it nil. Set before run().
    public var bootProjectUuid: String? {
        didSet { Core.setBootProjectUuid(bootProjectUuid) }
    }
    /// The current world's project identity — nil while unattributed; runtime-maintained.
    public private(set) var currentProjectUuid: String?
    public private(set) var currentWorldTrusted = false
    /// Observer for identity changes (the JS thread).
    public var onWorldChanged: ((String?, Bool) -> Void)?

    /// HostApp.worldChange: BEFORE the new bundle evaluates.
    func onWorldChange(_ projectUuid: String?, _ trusted: Bool) {
        currentProjectUuid = projectUuid
        currentWorldTrusted = trusted
        // The orientation lock is per world: the launcher always comes back unlocked.
        OrientationLock.apply(.auto)
        // So are the gl facade's frame bodies: a plugin's session is the outgoing world's.
        gl.worldChanged()
        onWorldChanged?(projectUuid, trusted)
    }

    /// Restart the current world in a fresh context (the error overlay's "Restart project"): the
    /// runtime's restart primitive, the twin of `_creatorApp.restart()`. Any thread; the swap runs
    /// at the next JS tick. NOT `Core.run(...)`: run is the BOOT entry — it retains its argument as
    /// the boot bundle and the restart source, so a restart snippet run through it restarted itself
    /// forever ("world swap failed", restart@[native code] × N).
    public func restartCurrentWorld() {
        if Thread.isMainThread { Core.restartWorld() }
        else { DispatchQueue.main.async { Core.restartWorld() } }
    }

    /// Quit to the boot world (the launcher) with launchUrl = url (nil clears) — the shared quit +
    /// cross-project notification-tap primitive. Any thread; the swap runs at the next JS tick.
    public func openLauncher(withUrl url: String?) {
        if Thread.isMainThread { Core.quitToLauncher(url: url) }
        else { DispatchQueue.main.async { Core.quitToLauncher(url: url) } }
    }

    // MARK: - Teardown

    /// Stop the frame loop and release what is registered against the system. The native runtime is
    /// process-global and stays; a viewer process ends with its engine anyway.
    public func dispose() {
        pause()
        statsOverlay.detach()
        appEvents.stop()
        gl.worldChanged()
        socket.dispose()
        media.dispose()
        nativeViews.destroyAll()
        localFiles.flush()
        if rendererServices != nil { CreatorCanvas.shared.clearAll() }
    }
}
