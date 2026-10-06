// The numbers the tree bridge shares between the runtime, the SDK and every host — a VERBATIM mirror
// of runtime/native/include/creator-pkg/tree-events.h (and sdk/src/ui/tree.ts, the Android host's
// TreeEvents.kt), checked by `bun run check:tree-consts`: the event kinds of Core.nodeEvent, the node
// flag mask HostUI.setFlags delivers (what the renderer reads for hit-testing and event routing), the
// track result bits, the destination kinds, the owned-handle kinds.
public enum TreeEvents {
    // ---- emit(id, kind, ...args) — `id` is the node, 0 for world-level events -----------------------
    public static let TREE_EVENT_LAYOUT = 1   // (id; left, top, width, height)  parent-relative, logical px
    public static let TREE_EVENT_TOUCH_START = 2   // (id; pointerId, x, y) → track result (TREE_TRACK_*)
    public static let TREE_EVENT_CLICK = 3   // (id; pointerId, x, y)
    public static let TREE_EVENT_LONG_PRESS = 4   // (id; pointerId, x, y) → 0 = no listener, else TREE_TRACK_HANDLED | track bits
    public static let TREE_EVENT_TOUCH_MOVE = 5   // (0; pointerId, x, y, dx, dy)   for the pointer's tracker
    public static let TREE_EVENT_TOUCH_END = 6   // (0; pointerId, x, y, dx, dy)
    public static let TREE_EVENT_TOUCH_CANCEL = 7   // (0; pointerId)
    public static let TREE_EVENT_SCROLL = 8   // (id; scrollTop)
    public static let TREE_EVENT_OVERSCROLL = 9   // (id; delta)
    public static let TREE_EVENT_SCROLL_RELEASE = 10   // (id)
    public static let TREE_EVENT_REFRESH = 11   // (id) → a promise the host waits for (pull-to-refresh)
    public static let TREE_EVENT_CHANGE = 12   // (id; value)
    public static let TREE_EVENT_FOCUS = 13   // (id)
    public static let TREE_EVENT_BLUR = 14   // (id)
    public static let TREE_EVENT_SUBMIT = 15   // (id; value)
    public static let TREE_EVENT_OVERLAY_TAP = 16   // (id)
    public static let TREE_EVENT_DETENT = 17   // (id; index)  a bottom sheet settled (gesture); -1 = drag-dismiss
    public static let TREE_EVENT_OPEN = 18   // (id; kind, destId)  a destination became visible (id = its node or 0)
    public static let TREE_EVENT_CLOSE = 19   // (id; kind, destId)  … stopped being visible
    public static let TREE_EVENT_BACK = 20   // (id; kind, destId) → true = handled; id 0 + TREE_DEST_NONE = the app-level handler
    public static let TREE_EVENT_PAGER_SELECT = 21   // (id; index)  a committed user swipe
    public static let TREE_EVENT_PAGER_POP = 22   // (id; depth)  a host-driven pop (edge swipe / back button)
    public static let TREE_EVENT_VLIST_SYNC = 23   // (id; unmountKeys[], mountKeys[])  SYNCHRONOUS — the SDK re-enters vlistMount
    public static let TREE_EVENT_VLIST_EDGE = 24   // (id; end)  onEndReached (true) / onStartReached (false)
    public static let TREE_EVENT_VIEW_EVENT = 25   // (0; viewId, event, dataJson)  a NativeView instance's event
    public static let TREE_EVENT_RESIZE = 26   // (0; width, height)  logical px
    public static let TREE_EVENT_ROUTER_CHANGE = 27   // (0; kind, destId)  the router's new top
    public static let TREE_EVENT_SCENE_TOUCH_START = 28   // (0; pointerId, x, y, entityId) → track result
    public static let TREE_EVENT_SCENE_CLICK = 29   // (0; pointerId, x, y, entityId)
    public static let TREE_EVENT_DETACHED = 30   // (id)  the runtime detached the root (a retired destination): unpin
    public static let TREE_EVENT_FREED = 31   // (0; ids[])  the runtime freed these nodes underneath their handles
    public static let TREE_EVENT_HOVER_ENTER = 32   // (id; x, y) → track result (mouse hover; the runtime's own slot)
    public static let TREE_EVENT_HOVER_MOVE = 33   // (0; x, y, dx, dy)
    public static let TREE_EVENT_HOVER_END = 34   // (0; x, y, dx, dy)
    public static let TREE_EVENT_HOVER_CANCEL = 35   // (0)
    // ---- setFlags(id, mask): listeners / traits the node has -------------------------------------
    // An INTERACTIVE node starts its own $hovered / $pressed / $focused scope: the engine cascades
    // an interaction class from a toggled ancestor down to it, never into it.
    public static let TREE_FLAG_INTERACTIVE = 1 << 0   // a touch target (button; screen / widget with onTouchStart)
    public static let TREE_FLAG_CLICK = 1 << 1
    public static let TREE_FLAG_LONG_PRESS = 1 << 2
    public static let TREE_FLAG_LAYOUT = 1 << 3
    public static let TREE_FLAG_SCROLL = 1 << 4
    public static let TREE_FLAG_OVERSCROLL = 1 << 5
    public static let TREE_FLAG_SCROLL_RELEASE = 1 << 6
    public static let TREE_FLAG_REFRESH = 1 << 7
    public static let TREE_FLAG_CHANGE = 1 << 8
    public static let TREE_FLAG_FOCUS = 1 << 9
    public static let TREE_FLAG_BLUR = 1 << 10
    public static let TREE_FLAG_SUBMIT = 1 << 11
    public static let TREE_FLAG_OVERLAY_TAP = 1 << 12
    public static let TREE_FLAG_DETENT = 1 << 13
    public static let TREE_FLAG_KEEP_ALIVE = 1 << 14
    public static let TREE_FLAG_BACK = 1 << 15   // has an onBack handler (the runtime's back chain asks it)
    public static let TREE_FLAG_VLIST_END = 1 << 16
    public static let TREE_FLAG_VLIST_START = 1 << 17
    public static let TREE_FLAG_HOVER = 1 << 18   // has an onMouseEnter listener
    // ---- the touchStart / longPress return value -------------------------------------------------
    public static let TREE_TRACK_CLAIM_MASK = 0xFF
    public static let TREE_TRACK_TRACKED = 1 << 8   // a track handler was registered (keep feeding the pointer)
    public static let TREE_TRACK_MOVE = 1 << 9   // … and it wants onMove
    public static let TREE_TRACK_HANDLED = 1 << 10   // longPress: a listener ran (swallow the trailing click)
    // ---- destination kinds (= creator-pkg.h VIEW_DEST_*) ------------------------------------------
    public static let TREE_DEST_SCREEN = 0
    public static let TREE_DEST_SCENE3D = 1
    public static let TREE_DEST_SCENE2D = 2
    public static let TREE_DEST_NATIVE = 3
    public static let TREE_DEST_VIDEO = 4
    public static let TREE_DEST_NONE = 0xFF
    // ---- owned-handle kinds (runtime/native/src/owned.h OwnedKind; the SDK's core/pins.ts freed channel) ----
    public static let OWNED_KIND_TREE = 0
    public static let OWNED_KIND_FETCH = 1
    public static let OWNED_KIND_GL_MATERIAL = 2
    public static let OWNED_KIND_GL_TEXTURE = 3
    public static let OWNED_KIND_GL_ENTITY = 4
    public static let OWNED_KIND_ENTITY_2D = 5
    public static let OWNED_KIND_MEDIA = 6
    public static let OWNED_KIND_TWEEN = 7
    public static let OWNED_KIND_CANVAS = 8
}
