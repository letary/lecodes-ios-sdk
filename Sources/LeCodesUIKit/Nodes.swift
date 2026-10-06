// The renderer's view map: one UINode per node id (the runtime's node pointer, the Int every HostUI
// slot carries). The runtime owns the tree; this is the renderer's side of it — created in
// HostUI.nodeFactory, dropped in releaseNode. Main thread only (the JS thread on this host).
import Foundation

public enum Nodes {
    private static var map: [Int: UINode] = [:]

    public static subscript(id: Int) -> UINode? { map[id] }

    static func put(_ id: Int, _ node: UINode) { map[id] = node }

    @discardableResult
    static func remove(_ id: Int) -> UINode? { map.removeValue(forKey: id) }

    /// Engine teardown: every id is dead from here on.
    public static func clear() { map.removeAll() }

    public static var count: Int { map.count }
    /// Every live node (a test's view of the map).
    public static var all: [UINode] { Array(map.values) }

    /// The renderer's node for a node of `type` — the wire type names of sdk/src/ui (UINode
    /// constructors). The node views come in with their steps (docs/plans/hosts-unification-plan.md, phase
    /// 6 steps 4 + 5); a type without its own class yet is a plain container.
    static func create(_ id: Int, _ type: String) -> UINode {
        switch type {
        case "text": return UINodeText(id: id, type: type)
        case "image": return UINodeImage(id: id, type: type)
        case "button": return UINodeButton(id: id, type: type)
        case "screen": return UINodeScreen(id: id, type: type)
        case "widget": return UINodeWidget(id: id, type: type)
        case "scrollable", "scrollableScreen": return UINodeScrollable(id: id, type: type)
        case "vlist": return UINodeVList(id: id, type: type)
        case "pager": return UINodePager(id: id, type: type)
        case "input", "textarea": return UINodeInput(id: id, type: type)
        case "video": return UINodeVideo(id: id, type: type)
        case "native": return UINodeNativeView(id: id, type: type)
        default: return UINodeContainer(id: id, type: type)   // column / row / box / spacer (a plain box, no paint)
        }
    }
}
