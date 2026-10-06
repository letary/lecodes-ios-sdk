// The runtime's entry points for the Swift host — the twin of hosts/android's Core (core-jni.cpp +
// le-value-jni.cpp) over the C face (lecodes-core.h): boot and the frame, the pushes into the live
// world, world control, the tree's pulls the renderer drives, the dispatch layer that settles the
// callback handles the host tables hand the host, the UI events by node id, registerCallback.
// Everything runs on the JS thread (the main thread) unless a comment says "any thread".
//
// A node id is an Int everywhere — the runtime's node pointer, the same number HostUI.nodeFactory
// handed the renderer, the key of its view map. Callback handles are JSCallback (Int).
import Foundation
import CLeCodesCore

public enum Core {
    /// The SDK/runtime version this host embeds (CREATOR_PKG_SDK_VERSION of creator-pkg/host.gen.h —
    /// sdk/package.json, the one version of the runtime set). Its major is the bundle ↔ runtime
    /// contract: the runtime refuses a bundle of another major, the launcher sends it as `?sdk=`
    /// when it fetches one, and the fetch table puts it in the User-Agent.
    public static let sdkVersion: String = CREATOR_PKG_SDK_VERSION

    // MARK: - The host contract

    /// Hand the runtime the host's tables ONCE, before initJS (a missing required slot aborts with its
    /// name). The Swift objects are retained for the life of the process.
    public static func setHostServices(_ services: HostServices) { HostGlue.bind(services) }

    /// HostDevice's data fields, rewritten in place (the runtime reads them on every access).
    public static func setLanguage(_ language: String) {
        HostGlue.c_device.pointee.language = UnsafePointer(strdup(language.isEmpty ? "en" : language))
    }
    public static func setPlatform(_ platform: String) {
        HostGlue.c_device.pointee.platform = UnsafePointer(strdup(platform.isEmpty ? "ios" : platform))
    }
    public static func setPixelRatio(_ ratio: Double) {
        HostGlue.c_device.pointee.pixelRatio = ratio > 0 ? ratio : 1
    }

    // MARK: - Boot and the frame

    public static func initJS() { lc_initJS() }
    /// Evaluate the boot bundle (main.js) in the boot world.
    public static func run(_ code: String) { lc_run(code) }
    /// One tick: timers, animations, the dispatch drain, JS jobs, the 3D frame when a scene is open.
    public static func runTick(_ nowMs: Int64) { lc_runTick(nowMs) }
    /// Display size in LOGICAL px: once before the bundle runs, then on every change.
    public static func onResize(width: Float, height: Float) { lc_onResize(width, height) }
    /// The system back gesture: true when the runtime consumed it.
    public static func onBackPressed() -> Bool { lc_onBackPressed() }
    /// …of a gesture that has moved the views already (the edge swipe, at its commit): the same
    /// chain, and the change of destination it makes plays no transition — the gesture was it.
    @discardableResult
    public static func backCommitted() -> Bool { lc_backCommitted() }
    /// Land every screen transition in flight now: the host is about to move the views itself.
    public static func settleTransitions() { lc_settleTransitions() }
    /// What onBackPressed WOULD do, with nothing done — the renderer's edge swipe asks when the
    /// gesture begins and moves the view the answer names; a committed gesture then calls
    /// onBackPressed, a cancelled one tells the runtime nothing.
    public static func backTarget() -> BackTarget {
        var node: UnsafeRawPointer?
        switch lc_backTarget(&node) {
        case Int32(LC_BACK_HANDLER.rawValue): return .handler(revealed: node.map { Int(bitPattern: $0) } ?? 0)
        case Int32(LC_BACK_PAGER.rawValue): return .pager(node.map { Int(bitPattern: $0) } ?? 0)
        case Int32(LC_BACK_ROUTER.rawValue): return .router(revealed: node.map { Int(bitPattern: $0) } ?? 0)
        default: return .none
        }
    }
    public enum BackTarget: Equatable {
        /// Nothing pops: only the app-level handler would run.
        case none
        /// A JS handler answers first. `revealed` = the screen root a pop would bring back when
        /// the handler is the current screen's own (the gesture runs speculatively: the handler
        /// answers on the commit, and a handler that keeps its screen snaps the gesture back);
        /// 0 for a shown widget's handler or a non-screen destination — nothing to move.
        case handler(revealed: Int)
        /// The pager whose current tab pops its top page.
        case pager(Int)
        /// The router pops; `revealed` = the screen root that comes back (0 when the revealed
        /// destination is a scene / native view / video).
        case router(revealed: Int)
    }

    // MARK: - Pushes into the live world (any thread)

    public static func emitAppEvent(_ event: String, data: String? = nil) { lc_emitAppEvent(event, data) }
    /// Update the HostInput.keyboardHeight answer BEFORE this, so a handler reading it agrees.
    public static func emitKeyboardEvent(height: Float, duration: Float) { lc_emitKeyboardEvent(height, duration) }
    /// kind: 0 keydown, 1 keyup, 2 gamepad connected, 3 disconnected.
    public static func emitInputEvent(kind: Int32, code: String, gamepad: Int32 = -1, repeat: Bool = false) {
        lc_emitInputEvent(kind, code, gamepad, `repeat` ? 1 : 0)
    }
    public static func emitTouchStart(fingerId: Int32, x: Float, y: Float) { lc_emitTouchStart(fingerId, x, y) }
    public static func emitTouchClick(fingerId: Int32, x: Float, y: Float) { lc_emitTouchClick(fingerId, x, y) }
    /// A NativeView instance's event (`_emitViewEvent(event, payload)`); nil = an event without one.
    public static func viewEmit(viewId: Int32, event: String, payload: LeValue? = nil) {
        lc_viewEmit(viewId, event, payload.flatMap { LeValue.builder([$0]) })
    }
    /// The same with the payload WRITTEN (a plugin channel's data); nothing written = no payload.
    public static func viewEmit(viewId: Int32, event: String, writing write: (WireOut) -> Void) {
        lc_viewEmit(viewId, event, WireOut.builder(write))
    }

    // MARK: - World control (docs/push-plan.md decision 9)

    public static func setTrustedLaunchers(_ uuids: [String]) {
        withCStrings(uuids) { ptrs in lc_setTrustedLaunchers(ptrs, Int32(uuids.count)) }
    }
    public static func setBootProjectUuid(_ uuid: String?) { lc_setBootProjectUuid(uuid) }
    public static func setLaunchUrl(_ url: String?) { lc_setLaunchUrl(url) }
    public static func quitToLauncher(url: String?) { lc_quitToLauncher(url) }
    /// The live world re-evaluated in a fresh context (identity kept) — the error overlay's restart.
    /// Deferred to the next tick. Never `run()` a restart snippet: run is the BOOT entry.
    public static func restartWorld() { lc_restartWorld() }

    // MARK: - The tree's pulls (the renderer's frame)

    /// One layout pass over every live root at (width, height) — the viewport minus the keyboard
    /// inset; the batch (readLayoutBatch) holds every node whose box changed.
    public static func layoutFrame(width: Float, height: Float) -> Int { Int(lc_layoutFrame(width, height)) }
    /// The batch of the last layoutFrame: its roots (the screen, the widgets, the pager pages the
    /// pass visited, in that order — the renderer applies from them), the node ids and their boxes
    /// as {left, top, right, bottom}, parent-relative, the core's px — points on iOS (rects has 4
    /// floats per node).
    public static func readLayoutBatch() -> (roots: [Int], nodes: [Int], rects: [Float]) {
        let count = Int(lc_layoutBatchCount())
        guard count > 0, let nodes = lc_layoutBatchNodes(), let rects = lc_layoutBatchRects() else { return ([], [], []) }
        var roots: [Int] = []
        if let r = lc_layoutBatchRoots() { roots = (0..<Int(lc_layoutBatchRootCount())).map { Int(bitPattern: r[$0]) } }
        return (roots, (0..<count).map { Int(bitPattern: nodes[$0]) }, Array(UnsafeBufferPointer(start: rects, count: count * 4)))
    }
    /// The 3D frames' pacing, counted by the engine while it is on (creator-gl setFramePacing /
    /// getFramePacing; the stats overlay asks once a second): [frames, timed, even, periods,
    /// periodMs, gpuFrameMs] since the previous call. nil on a build without the 3D engine or before
    /// one is up.
    public static func setFramePacing(_ on: Bool) { lc_setFramePacing(on) }
    public static func framePacing() -> [Float]? {
        var out = [Float](repeating: 0, count: 6)
        return lc_framePacing(&out) ? out : nil
    }
    /// The one root laid out `overlap` px shorter (the focused input's); 0 / <= 0 clears.
    public static func setShrunkRoot(_ root: Int, overlap: Float) { lc_setShrunkRoot(node(root), overlap) }
    public static func rootLayoutHeight(_ root: Int, height: Float) -> Float { lc_rootLayoutHeight(node(root), height) }
    /// The box an attached widget root lays out at; w or h <= 0 clears.
    public static func setWidgetBox(_ root: Int, width: Float, height: Float) { lc_setWidgetBox(node(root), width, height) }

    public static func pagerLayoutPages(_ pager: Int, width: Float, height: Float) { lc_pagerLayoutPages(node(pager), width, height) }
    public static func pagerDidSelect(_ pager: Int, index: Int) { lc_pagerDidSelect(node(pager), Int32(index)) }
    public static func pagerTabCount(_ pager: Int) -> Int { Int(lc_pagerTabCount(node(pager))) }
    public static func pagerSelectedIndex(_ pager: Int) -> Int { Int(lc_pagerSelectedIndex(node(pager))) }
    public static func pagerStackLen(_ pager: Int, tab: Int) -> Int { Int(lc_pagerStackLen(node(pager), Int32(tab))) }
    /// The page node at (tab, pos), 0 when out of bounds.
    public static func pagerPageNode(_ pager: Int, tab: Int, pos: Int) -> Int { Int(bitPattern: lc_pagerPageNode(node(pager), Int32(tab), Int32(pos))) }

    // MARK: - Text measure (the renderer's)

    /// The measure creator-ui calls for a text node during layout: (screenId, node, width,
    /// widthMode, height, heightMode) → the size packed by `packMeasure`. REQUIRED before the first
    /// layout; a host without text answers 0. A `@convention(c)` closure: no captures.
    public static func setMeasureFunc(_ fn: @escaping @convention(c) (Int32, UnsafeRawPointer?, Float, UInt8, Float, UInt8) -> Int64) {
        lc_setMeasureFunc(fn)
    }
    /// The measure result's packing: the two floats' bit patterns, width high, height low.
    public static func packMeasure(width: Float, height: Float) -> Int64 {
        Int64(bitPattern: (UInt64(width.bitPattern) << 32) | UInt64(height.bitPattern))
    }

    // MARK: - The log

    /// Every runtime log line with its level (0 debug — console.log, 1 info, 2 warn, 3 error), on
    /// whichever thread logged it; nil restores stdout. ONE sink per process.
    public static func setLogSink(_ sink: ((Int, String) -> Void)?) {
        logSink = sink
        if sink == nil { lc_setLogSink(nil) }
        else { lc_setLogSink({ level, line in Core.logSink?(Int(level), line.map { String(cString: $0) } ?? "") }) }
    }
    private static var logSink: ((Int, String) -> Void)?

    // MARK: - Debug

    /// The tree of truth as JSON (identical on every host).
    public static func debugDump() -> String { lc_debugDump().map { String(cString: $0) } ?? "" }
    public static func debugPaint(_ node: Int) -> String { lc_debugPaint(Core.node(node)).map { String(cString: $0) } ?? "null" }

    // MARK: - Dispatch: settling the callback handles (any thread)

    /// Call an OWNED heap handle with `args`, then free it (a fetch onComplete, …).
    public static func call(_ callback: JSCallback, _ args: [LeValue] = []) { lc_dispatchCall(callback, LeValue.builder(args)) }
    /// Call a BORROWED long-lived handle (a socket's onMessage, an onProgress): never freed here.
    public static func callBorrowed(_ callback: JSCallback, _ args: [LeValue] = []) { lc_dispatchCallBorrowed(callback, LeValue.builder(args)) }
    /// Settle a pair: onComplete with `args`, onReject freed.
    public static func resolve(_ onComplete: JSCallback, reject onReject: JSCallback, _ args: [LeValue] = []) {
        lc_resolve(onComplete, onReject, LeValue.builder(args))
    }
    /// Settle a pair with ONE value, written (a plugin channel's result); nothing written = none.
    public static func resolve(_ onComplete: JSCallback, reject onReject: JSCallback, writing write: (WireOut) -> Void) {
        lc_resolve(onComplete, onReject, WireOut.builder(write))
    }
    /// An event of a plugin channel through a BORROWED handle: its name, then the payload written
    /// (nothing written = no payload).
    public static func emitBorrowed(_ callback: JSCallback, event: String, writing write: (WireOut) -> Void) {
        lc_dispatchCallBorrowed(callback, WireOut.builder { out in
            out.string(event)
            write(out)
        })
    }
    /// Settle a pair: onReject with an Error(message), onComplete freed.
    public static func reject(_ onComplete: JSCallback, reject onReject: JSCallback, message: String) {
        lc_reject(onComplete, onReject, message)
    }
    /// Release a handle that will never be called.
    public static func free(_ callback: JSCallback) { lc_free(callback) }

    // MARK: - UI events, host → runtime, by node id

    /// kind = TreeEvents.TREE_EVENT_*; only a kind the node's flag mask declares.
    public static func nodeEvent(_ node: Int, kind: Int, _ args: [LeValue] = []) { lc_nodeEvent(Core.node(node), Int32(kind), LeValue.builder(args)) }
    public static func nodeLayout(_ node: Int, left: Float, top: Float, width: Float, height: Float) { lc_nodeLayout(Core.node(node), left, top, width, height) }
    public static func nodeScroll(_ node: Int, scrollTop: Float) { lc_nodeScroll(Core.node(node), scrollTop) }
    public static func touchStart(_ node: Int, pointerId: Int32, x: Float, y: Float) { lc_touchStart(Core.node(node), pointerId, x, y) }
    public static func touchMove(pointerId: Int32, x: Float, y: Float, deltaX: Float, deltaY: Float) { lc_touchMove(pointerId, x, y, deltaX, deltaY) }
    public static func touchEnd(pointerId: Int32, x: Float, y: Float, deltaX: Float, deltaY: Float) { lc_touchEnd(pointerId, x, y, deltaX, deltaY) }
    public static func touchCancel(pointerId: Int32) { lc_touchCancel(pointerId) }
    public static func touchClick(_ node: Int, pointerId: Int32, x: Float, y: Float) { lc_touchClick(Core.node(node), pointerId, x, y) }
    public static func longPress(_ node: Int, pointerId: Int32, x: Float, y: Float) { lc_longPress(Core.node(node), pointerId, x, y) }
    /// Pull-to-refresh: `completion` runs on the JS thread once the SDK handler's promise settled.
    public static func refresh(_ node: Int, completion: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Completion(completion)).toOpaque()
        lc_refresh(Core.node(node), { user in
            Unmanaged<Completion>.fromOpaque(user!).takeRetainedValue().run()
        }, box)
    }

    // MARK: - registerCallback: a host method JS calls SYNCHRONOUSLY

    /// Install `fn` as the JS global `path` ("myPlugin.fn": intermediate objects are created) in
    /// every world, forever. It runs on the JS thread inside the JS call: keep it quick.
    public static func registerCallback(_ path: String, argsCount: Int, _ fn: @escaping ([LeScalar]) -> LeScalar) {
        let box = Unmanaged.passRetained(Callback(fn)).toOpaque()   // permanent, like the registration
        lc_registerCallback(path, Int32(argsCount), { ctx, argc, argv, result in
            let cb = Unmanaged<Callback>.fromOpaque(ctx!).takeUnretainedValue()
            let args = (0..<Int(argc)).map { LeScalar(argv![$0]) }
            result!.pointee = cb.fn(args).cScalar
        }, box)
    }

    // MARK: - 3D (no-ops in a variant without creator-gl)

    /// BEFORE the app creates its engine: Filament on its NOOP backend (no GPU, nothing drawn; the
    /// simulation runs as on a rendering host) — the engine-only host.
    public static func setHeadlessBackend(_ on: Bool) { lc_setHeadlessBackend(on) }
    /// A swap chain without a window (the engine's frame lifecycle for a host that presents nothing).
    public static func createSwapChainHeadless(width: UInt32, height: UInt32) { lc_createSwapChainHeadless(width, height) }
    public static func setViewport(width: UInt32, height: UInt32) { lc_setViewport(width, height) }
    /// The CAMetalLayer Filament presents into.
    public static func createSwapChain(layer: UnsafeMutableRawPointer) { lc_createSwapChain(layer) }
    public static func destroySwapChain() { lc_destroySwapChain() }
    public static var sceneRenderScale: Float { lc_sceneRenderScale() }
    public static var frameRendered: Bool { lc_frameRendered() }
    public static var sceneOpen: Bool { lc_sceneOpen() }
    public static func setStepEveryTick(_ on: Bool) { lc_setStepEveryTick(on) }

    // MARK: - 2D (no-ops in a variant without creator-2d)

    public static func scene2dEnsureInited() { lc_2dEnsureInited() }
    public static var scene2dOpen: Bool { lc_2dSceneOpen() }
    public static func scene2dRenderFrame(nowMs: Int64) { lc_2dRenderFrame(nowMs) }
    /// phase: 0 down, 1 move, 2 up, 3 cancel; logical coordinates.
    public static func scene2dEmitPointer(phase: Int32, pointerId: Int32, x: Float, y: Float) { lc_2dEmitPointer(phase, pointerId, x, y) }

    // MARK: - helpers

    static func node(_ id: Int) -> UnsafeRawPointer? { UnsafeRawPointer(bitPattern: id) }

    private final class Completion {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
    private final class Callback {
        let fn: ([LeScalar]) -> LeScalar
        init(_ fn: @escaping ([LeScalar]) -> LeScalar) { self.fn = fn }
    }

    private static func withCStrings(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> Void) {
        let ptrs: [UnsafePointer<CChar>?] = strings.map { UnsafePointer(strdup($0)) }
        defer { for p in ptrs { Foundation.free(UnsafeMutablePointer(mutating: p)) } }
        ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
