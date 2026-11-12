// The renderer's frame — the twin of renderers/android's FrameBatcher.kt. Main thread only; the two
// buffer sets are for RE-ENTRANCY, not threads: a request made while `runTick` drains (an
// updateLayout that re-measures and signals) lands in the write buffers and is picked up next tick.
//
// The host calls `runTick()` right after Core.runTick and provides `onLayoutFrame`: Core.layoutFrame
// at the viewport minus the keyboard inset, LayoutBatch.load, then the apply walk from every live
// root (the presented screen, the shown widgets, the pager pages).
import LeCodesCore
import UIKit

public enum FrameBatcher {
    private static var scheduled = false

    // The write buffers. A measured leaf is held as the NODE, never its raw id: the id can be freed
    // between the request and the drain — the runtime frees a destroyed subtree's yoga nodes at the
    // end of its entry point, after the commit that brought their releaseNode, still inside
    // Core.runTick and so before this drain (docs/tree.md "The host commit") — and markNodeDirty on
    // freed memory is a use-after-free; the node carries the isRemoved flag the drain filters on.
    private static var nodesToUpdate: [ObjectIdentifier: UINode] = [:]
    private static var leafsToMeasure: [ObjectIdentifier: UINode] = [:]
    // The processing buffers — runTick reads them after the swap.
    private static var processingNodes: [ObjectIdentifier: UINode] = [:]
    private static var processingLeafs: [ObjectIdentifier: UINode] = [:]

    /// The mutation tick's layout pass, provided by the host's root view: Core.layoutFrame +
    /// LayoutBatch.load + the apply walk from every root. Without it (no root view yet) the frame
    /// recalculates the last root only, and the one-shot flags stay for the attach-time pass.
    public static var onLayoutFrame: (() -> Void)?

    /// `node` wants its box re-applied after the pass (a content change that redraws).
    public static func request(_ node: UINode, measure: Bool = false) {
        nodesToUpdate[ObjectIdentifier(node)] = node
        if measure { leafsToMeasure[ObjectIdentifier(node)] = node }
        scheduled = true
    }

    /// A measured leaf changed its intrinsic size (an image decoded, a font arrived) while it may
    /// have no live view: the dirty mark must not be dropped with the repaint — the next layout pass
    /// of its root re-measures it.
    public static func requestMeasure(_ node: UINode) {
        leafsToMeasure[ObjectIdentifier(node)] = node
        scheduled = true
    }

    /// The sheets taken out of their root since the last frame. One the same commit inserted again
    /// was MOVED (a show() to the front: the runtime re-inserts a root's widgets in their new order)
    /// and keeps where it stands; one still out at the frame owes its entrance (UINodeWidget).
    private static var detachedWidgets: [ObjectIdentifier: UINodeWidget] = [:]

    static func widgetDetached(_ widget: UINodeWidget) {
        detachedWidgets[ObjectIdentifier(widget)] = widget
    }

    private static func swapBuffers() -> Bool {
        guard scheduled else { return false }
        scheduled = false
        swap(&processingNodes, &nodesToUpdate)
        swap(&processingLeafs, &leafsToMeasure)
        return true
    }

    /// One frame, after Core.runTick.
    public static func runTick() {
        // The removals of the commits since the last frame are final now: a sheet still out of its
        // root owes its entrance (a moved one is in its root again).
        if !detachedWidgets.isEmpty {
            let detached = Array(detachedWidgets.values)
            detachedWidgets.removeAll()
            for widget in detached { widget.settleDetached() }
        }
        // Every style write since the last frame sits in the core's dirty paint records — apply them
        // to the nodes BEFORE the layout pass. A non-empty batch counts as a mutation: the nodes'
        // setters request() themselves, so the pass below runs.
        PaintBatch.sync()
        // A layout prop written from JS marks its yoga node dirty and stops there — unlike a paint
        // prop it reaches no renderer call, so nothing requests a frame. Ask the core once per tick.
        if CreatorUI.consumeNeedsLayout() { scheduled = true }
        guard swapBuffers() else { return }
        defer {
            // Always drain, even if the pass threw — a failed frame must not replay stale work.
            LayoutBatch.clear()
            processingLeafs.removeAll(keepingCapacity: true)
            processingNodes.removeAll(keepingCapacity: true)
        }
        // Through `boxNode`: a text that asked as a root may be an inline run by now (the same commit
        // linked it) — its paragraph is the one measured; dirtying the run would trip Yoga's assert.
        for leaf in processingLeafs.values where !leaf.isRemoved {
            let measured = leaf.boxNode
            if !measured.isRemoved { CreatorUI.markNodeDirty(measured.id) }
        }
        if let layoutFrame = onLayoutFrame {
            layoutFrame()
        } else {
            CreatorUI.recalculate()
        }
        for requested in processingNodes.values where !requested.isRemoved {
            let node = requested.boxNode   // a run has no box to walk: its paragraph's
            if node.isRemoved { continue }
            node.walkRequested = true
            node.updateLayout()
            node.walkRequested = false
        }
    }

    public static func clear() {
        scheduled = false
        nodesToUpdate.removeAll()
        leafsToMeasure.removeAll()
    }
}
