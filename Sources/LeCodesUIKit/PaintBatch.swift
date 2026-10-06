// The frame's paint sync — the pull half of the host contract (the per-prop handler channel is gone
// since 2026-09-24). Once per frame, BEFORE the layout pass (a text node's font must be the one it
// is measured with), `sync` drains the core's dirty records in one crossing and hands each to its
// node's UINode.applyPaint. A measure the runtime runs earlier in the tick (it lays a screen out
// when it presents it) pulls the node's current record itself (`applyPending`), so nothing ever
// measures against stale paint — the paint-state trap. Main thread only, like LayoutBatch.
import LeCodesCore
import UIKit

/// A view over one CUIPaint record (creator-ui/paint.gen.h) in the core's memory: word offsets,
/// mask bits and enum codes from the generated CuiPaint; floats stored as raw bits; color words the
/// core's 0xRRGGBBAA (the same record on every host). Valid for the duration of the call it was
/// handed in — never kept.
public struct PaintRecord {
    let base: UnsafePointer<UInt32>

    public func word(_ w: Int) -> UInt32 { base[w] }
    public func float(_ w: Int) -> Float { Float(bitPattern: base[w]) }
    /// A color word, 0xRRGGBBAA.
    public func color(_ w: Int) -> UInt32 { base[w] }
    public func bool(_ w: Int) -> Bool { float(w) >= 0.5 }
    /// The field has a value (own, inherited, or a registry default).
    public func has(_ bit: Int) -> Bool { CuiPaint.has(base[CuiPaint.presentLo], base[CuiPaint.presentHi], bit) }
    /// The field changed since the last collect.
    public func dirty(_ bit: Int) -> Bool { CuiPaint.has(base[CuiPaint.dirtyLo], base[CuiPaint.dirtyHi], bit) }
    public var anyDirty: Bool { base[CuiPaint.dirtyLo] != 0 || base[CuiPaint.dirtyHi] != 0 }
    public func string(_ w: Int) -> String { CreatorUI.string(base[w]) }
    public func gradient(_ w: Int) -> Gradient? { CreatorUI.gradient(base[w]) }
    /// The 3x3 transform (column-major in the record) as an affine transform, nil for identity.
    public func transform(_ w: Int) -> CGAffineTransform? {
        let a = float(w), b = float(w + 1), c = float(w + 3), d = float(w + 4), tx = float(w + 6), ty = float(w + 7)
        if a == 1, b == 0, c == 0, d == 1, tx == 0, ty == 0 { return nil }
        return CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d), tx: CGFloat(tx), ty: CGFloat(ty))
    }
}

public enum PaintBatch {
    /// Drain the core's dirty records into their nodes. Under one transaction with the implicit
    /// actions off: a record is a MODEL write, never an animation — a sublayer property (the
    /// gradient's radius, an edge's frame) written every frame by a runtime-driven tween would
    /// otherwise pick up Core Animation's 0.25 s implicit action and trail the value.
    public static func sync() {
        let count = CreatorUI.paintCollect()
        guard count > 0, let records = CreatorUI.paintRecords() else { return }
        let nodes = CreatorUI.paintNodes(count: count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for i in 0..<count {
            guard let ptr = nodes[i], let node = Nodes[Int(bitPattern: ptr)] else { continue }
            node.applyPaint(PaintRecord(base: records + i * CuiPaint.words))
        }
    }

    /// A node about to be measured outside the frame's sync: apply its record now if it moved.
    public static func applyPending(_ node: UINode) {
        guard !node.isRemoved, let ptr = CreatorUI.paintOf(node.id) else { return }
        let record = PaintRecord(base: ptr)
        if record.anyDirty { node.applyPaint(record) }
    }
}
