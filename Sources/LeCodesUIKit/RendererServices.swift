// What the renderer needs from the host it runs in, beyond the runtime — the twin of
// renderers/android's RendererServices.kt. The renderer declares it; the host implements it (on
// iOS LeCodesEngine, as one object) and hands it to HostUIRenderer, which makes it
// `rendererServices` — the one host-shaped global the renderer reads. Everything here lives as
// long as the engine; the per-window half is UIRootHost. Every call comes on the main (= JS)
// thread unless a member says otherwise.
//
// Besides the two protocols a host drives the renderer's frame itself: FrameBatcher.runTick()
// after Core.runTick, FrameBatcher.onLayoutFrame (its per-root layout pass), and the seeds
// UINode.density / UINode.appRoot.
import AVFoundation
import LeCodesCore
import UIKit

public protocol RendererServices: AnyObject {
    // ---- presentation: HostUI's openView / dropView / closeView / layers, for the host's navigator
    /// Mount `dest` as the current destination, over what is shown or under it; what WAS shown
    /// stays mounted until its dropView (the runtime moves the screens meanwhile).
    func openView(_ dest: PresentedDest, above: Bool)
    /// The destination that left is unmounted.
    func dropView(_ dest: PresentedDest)
    /// Nothing is the current destination.
    func closeView()
    /// A LAYER root is shown (HostUI.layerOpen): a pass-through root the runtime lays out at the
    /// viewport whose children are widgets (docs/plans/widgets-plan.md) — `surface` true = the
    /// presented surface's content, over the surface and under every screen; false = the app layer,
    /// above everything.
    func layerOpen(_ node: UINode, surface: Bool)
    /// The layer is hidden; its subtree stays (releaseNode says when it is gone).
    func layerClose(_ node: UINode)
    /// The runtime freed `node` (HostUI.releaseNode): the host forgets it wherever it holds it.
    func nodeReleased(_ node: UINode)
    /// HostUI.registerFont — always settles the (onComplete, onReject) pair.
    func registerFont(url: String, fontFamily: String, weight: Int, style: Int, onComplete: JSCallback, onReject: JSCallback)
    func showToast(message: String, duration: Int)

    // ---- registerView platform views (the registry stays in the host) ------------------------------
    func isViewSupported(_ name: String) -> Bool
    /// The contract version of the view `name`: 0 when there is none, 1 for one written by hand.
    func viewVersion(_ name: String) -> Int32
    /// `args` = the call's arguments, the runtime's value: valid for the call only. (A registered
    /// view is a destination: the host presents it — no node of the renderer holds one.)
    func viewCall(viewId: Int, method: String, args: WireIn, onComplete: JSCallback, onReject: JSCallback)

    // ---- a flow's input (HostUI.debugInput; `lecodes test --ios`): the root view is the host's -------
    /// kind 0 / 1 / 2 a pointer pressed / moved / released at (x, y) of the root view, through its
    /// hit-test; 3 `text` typed into the focused field; 4 what scrolls under (x, y) moved by
    /// (dx, dy). True = taken; it lands on the next turn of the JS thread.
    func debugInput(kind: Int32, x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat, text: String) -> Bool

    // ---- host nodes (`UIHostNode`, docs/plans/host-node-plan.md): the registry stays in the host -----
    /// The contract version the half registered as `kind` was generated from: 0 when there is none.
    func nodeVersion(_ kind: String) -> Int32
    /// A method of the instance behind the host node `node`; `args` = the call's arguments, the
    /// runtime's value, valid for the call only. Settles the pair exactly once (a node with no
    /// instance rejects).
    func nodeCall(node: Int, method: String, args: WireIn, onComplete: JSCallback, onReject: JSCallback)
    /// The instance of `kind` for the host node `node`, made now (UINodeHost, at the node's first
    /// `kind`); nil when no half registered the kind. `invalidateSize` is the holder's re-measure: the
    /// host calls it on the main thread when the instance asks.
    func makeHostNode(node: Int, kind: String, invalidateSize: @escaping () -> Void) -> HostNodeContent?
    /// The host node `node` was released: its instance is destroyed.
    func hostNodeReleased(node: Int)

    // ---- the host's buffer store (`id:<n>` sources, canvas images) ----------------------------------
    /// nil when the id is unknown or evicted.
    func buffer(id: Int) -> Data?

    // ---- network --------------------------------------------------------------------------------------
    /// GET `url` in the device cache's mode `cache` (docs/cache.md: "force-cache" / "fallback" /
    /// "no-store", "" = none) — the host carries the mode out, in the one function its own fetch goes
    /// through. `onSuccess` gets the body and its HTTP status (any status; 200 for the kept copy,
    /// 0 for a url that is not HTTP), `onError` any other failure. Never called back from inside
    /// fetch() itself, nor after `cancel`; both may arrive on a worker thread.
    func fetch(url: String, cache: String, onSuccess: @escaping (Data, Int) -> Void, onError: @escaping () -> Void) -> Cancel
    /// Keep `data` — the body of a 200 the renderer already holds — as the device cache's copy of
    /// `url`: a load is shared by every asker of its url, and one that keeps the copy may join a
    /// load made in a mode that does not (ImageLoader). Main thread; the host writes elsewhere.
    func keepCopy(url: String, data: Data)

    // ---- media: the player behind a video node's playerId ------------------------------------------
    func mediaPlayer(id: Int) -> AVPlayer?
}

public protocol Cancel: AnyObject {
    func cancel()
}

/// A host node's instance as its holder (UINodeHost) drives it: what the host's registry hands the
/// renderer for a node of a registered kind (on iOS the plugin's HostNodeInstance of
/// hosts/apple/lecodes, behind an adapter). Main thread.
public protocol HostNodeContent: AnyObject {
    /// The plugin's view: laid out over the node's box, above the box's paint.
    var view: UIView { get }
    /// The instance paints its background and backdrop (`paints: "self"`): the holder leaves them.
    var paintsSelf: Bool { get }
    /// A prop the SDK wrote, as its wire text; nil = cleared.
    func setProperty(_ name: String, _ value: String?)
    /// A color style of the node's paint record, as the core resolved it; nil = none is set.
    func setStyle(_ name: String, color: UIColor?)
    /// A number style of the node's paint record, a length in logical px; nil = none is set.
    func setStyle(_ name: String, number: Double?)
    /// The node's size in points: a nil side is unconstrained, an `atMost` side a maximum, any other
    /// side exact.
    func measure(width: CGFloat?, widthAtMost: Bool, height: CGFloat?, heightAtMost: Bool) -> CGSize
}

/// Set by HostUIRenderer's initializer — every new engine overwrites it, nothing clears it (a view's
/// teardown callbacks may still arrive after the engine is gone).
var rendererServices: RendererServices!

/// Destination kinds — the runtime's TREE_DEST_* (creator-pkg/tree-events.h).
public enum DestKind {
    public static let screen = TreeEvents.TREE_DEST_SCREEN
    public static let scene3d = TreeEvents.TREE_DEST_SCENE3D
    public static let scene2d = TreeEvents.TREE_DEST_SCENE2D
    public static let native = TreeEvents.TREE_DEST_NATIVE
    public static let none = TreeEvents.TREE_DEST_NONE
}

/// A destination the runtime presents: `node` = the screen root (the screen kind); `id` = the
/// sceneId / viewId (0 for a screen).
public struct PresentedDest {
    public let kind: Int
    public let node: UINode?
    public let id: Int
    public let viewName: String?
    public let paramsJson: String?
    public init(kind: Int, node: UINode?, id: Int, viewName: String?, paramsJson: String?) {
        self.kind = kind; self.node = node; self.id = id; self.viewName = viewName; self.paramsJson = paramsJson
    }
}
