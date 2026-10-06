// The mutation tick's layout batch — the bridge between the runtime's frame pass (Core.layoutFrame:
// the screen + widget + pager-page roots recalculated, every node that pass visited collected) and
// the renderer's apply walks. One crossing replaces per-node polling. The batch names its ROOTS
// (`roots`: the visited ones, the core's order — screen, widgets, pages): the root host applies the
// batch from them, so it keeps no list of roots of its own and knows nothing of pagers' pages.
//
// Two questions, both answered WITHOUT consuming anything:
//  - `read` — the node's current box: from the batch when the frame's pass visited the node, the
//    live yoga box otherwise (detached vlist item roots, walks outside the batch window). The walk
//    diffs it against the box it applied last time — "changed" is the renderer's comparison, not a
//    one-shot flag someone else may have taken first, which is what makes the apply walk
//    idempotent (a re-walk, a rebuilt view, a widget shown again all read the same answer).
//  - `visited` — the frame's pass went through this node. Yoga's visited set is connected from each
//    root, so a walk may prune any subtree whose node is not in it and must descend where it is.
//    visited ≠ changed: a cache-hit sibling is collected with an identical rect.
//
// Main thread only: loaded, drained and cleared inside FrameBatcher.runTick.
import LeCodesCore
import UIKit

public enum LayoutBatch {
    public private(set) static var active = false
    /// The roots the frame's pass visited, in the core's order: what the apply walks start from.
    public private(set) static var roots: [Int] = []
    private static var rects: [Float] = []
    private static var index: [Int: Int] = [:]   // node id → offset into rects

    /// Drain the runtime's collection (after Core.layoutFrame returned its size).
    public static func load() {
        let batch = Core.readLayoutBatch()
        roots = batch.roots
        rects = batch.rects
        index.removeAll(keepingCapacity: true)
        for (i, node) in batch.nodes.enumerated() { index[node] = i * 4 }
        active = true
    }

    /// The batch onto its roots' views: each visited root's walk (a page's own box stays its
    /// cell's — frameOwnedByHost — only its content moves).
    public static func applyFromRoots() {
        for id in roots { if let root = Nodes[id], !root.isRemoved { root.updateLayout() } }
    }

    /// The node's current box in its parent's space, logical px.
    public static func read(_ node: Int) -> CGRect {
        if active, let i = index[node] {
            return CGRect(x: CGFloat(rects[i]), y: CGFloat(rects[i + 1]), width: CGFloat(rects[i + 2] - rects[i]), height: CGFloat(rects[i + 3] - rects[i + 1]))
        }
        let l = CreatorUI.layout(node)
        return CGRect(x: CGFloat(l.left), y: CGFloat(l.top), width: CGFloat(l.width), height: CGFloat(l.height))
    }

    /// The frame's layout pass visited this node — its subtree may hold more batch entries.
    public static func visited(_ node: Int) -> Bool { active && index[node] != nil }

    public static func clear() {
        active = false
        roots.removeAll(keepingCapacity: true)
        index.removeAll(keepingCapacity: true)
    }
}
