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
    // ---- presentation: HostUI's openView / dropView / closeView / widgets, for the host's navigator
    /// Mount `dest` as the current destination, over what is shown or under it; what WAS shown
    /// stays mounted until its dropView (the runtime moves the screens meanwhile).
    func openView(_ dest: PresentedDest, above: Bool)
    /// The destination that left is unmounted.
    func dropView(_ dest: PresentedDest)
    /// Nothing is the current destination.
    func closeView()
    func widgetOpen(_ node: UINode, owner: WidgetOwner)
    func widgetClose(_ node: UINode)
    /// The runtime freed `node` (HostUI.releaseNode): the host forgets it wherever it holds it.
    func nodeReleased(_ node: UINode)
    /// HostUI.registerFont — always settles the (onComplete, onReject) pair.
    func registerFont(url: String, fontFamily: String, weight: Int, style: Int, onComplete: JSCallback, onReject: JSCallback)
    func showToast(message: String, duration: Int)

    // ---- registerView platform views (the registry stays in the host) ------------------------------
    func isViewSupported(_ name: String) -> Bool
    /// The contract version of the view `name`: 0 when there is none, 1 for one written by hand.
    func viewVersion(_ name: String) -> Int32
    /// `args` = the call's arguments, the runtime's value: valid for the call only.
    func viewCall(viewId: Int, method: String, args: WireIn, onComplete: JSCallback, onReject: JSCallback)
    /// The live view of instance `viewId` (created on first sight), or the host's placeholder when no
    /// factory is registered for `name`.
    func nativeView(viewId: Int, name: String?, paramsJson: String?) -> UIView

    // ---- the host's buffer store (`id:<n>` sources, canvas images) ----------------------------------
    /// nil when the id is unknown or evicted.
    func buffer(id: Int) -> Data?

    // ---- network --------------------------------------------------------------------------------------
    /// GET `url`; `onSuccess` gets the body (any HTTP status), `onError` any other failure. Never
    /// called back from inside fetch() itself; both may arrive on a worker thread.
    func fetch(url: String, onSuccess: @escaping (Data) -> Void, onError: @escaping () -> Void) -> Cancel

    // ---- media: the player behind a video node's playerId ------------------------------------------
    func mediaPlayer(id: Int) -> AVPlayer?
}

public protocol Cancel: AnyObject {
    func cancel()
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
    public static let video = TreeEvents.TREE_DEST_VIDEO
    public static let none = TreeEvents.TREE_DEST_NONE
}

/// A destination the runtime presents: `node` = the screen root / the video node (screen and video
/// kinds); `id` = the sceneId / viewId (0 for a screen).
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

/// A widget's attachTo owner — the widget is visible only while this destination is current. kind ==
/// DestKind.none → unattached (a global overlay, always visible). For a screen / pager-page owner
/// `node` is the owner's root; `id` is the sceneId / viewId of a scene / native owner.
public struct WidgetOwner {
    public let kind: Int
    public let id: Int
    public let node: UINode?
    public init(kind: Int, id: Int, node: UINode?) { self.kind = kind; self.id = id; self.node = node }
    public static let global = WidgetOwner(kind: DestKind.none, id: 0, node: nil)
    public var isGlobal: Bool { kind == DestKind.none }
}
