// The HOLDER of a host node (docs/plans/host-node-plan.md): the one renderer class behind every
// `"hostnode"` — a node of the layout a plugin's native half draws (the tab bar, plugins/native-ui),
// declared by the plugin's contract (`UIHostNode<"kind", Props, Events>`) and generated into the SDK
// element and the native glue. The holder knows no contract: it hands everything to the instance the
// host's registry made for the node's kind, through HostNodeContent (RendererServices.makeHostNode).
//
// The rules:
//  - A LEAF: no children (the SDK's element takes none), so a UINode, not a container.
//  - The instance is made at the node's first `kind` write (the generated constructor writes it
//    first, before any prop); a later `kind` is ignored. A kind no half registered is an empty box
//    (one log line per kind — the SDK warned already); the props then go nowhere.
//  - Every other content write is a PROP, handed over as its wire text (`setProperty`): the generated
//    glue decodes it by the contract.
//  - The box: the node's view is a plain box view (HostNodeBoxView) with the instance's view inside
//    at the box's bounds, so BoxPaint paints over any UIView — position, size, opacity, transform,
//    shadow, display, the borders, the radius, `overflow` (clipsToBounds follows it as for any node:
//    `visible`, the default, lets a control's press growth leave the box), and the background and
//    the backdrop unless the instance paints them itself (`paintsSelf`, the contract's `paints:
//    "self"` — BoxPaint.applyBackdrop leaves the box then).
//  - The styles: every color and number field of the paint record a host node may list
//    (NODE_STYLES of tools/cli/src/plugin/contract.ts, below — `backgroundColor` and
//    `backdropBlur` only for `paintsSelf`) is forwarded when the record marks it dirty, resolved by
//    the core (var(), theme changes): `setStyle(name, color:)` / `setStyle(name, number:)`, nil =
//    none set, a length in LOGICAL px (the record's px over UINode.density). The generated glue
//    keeps the ones its contract lists.
//  - The size: the runtime gives the node a measure func when the SDK created it with the measure
//    flag (the contract's `measure: true`) and calls `measure` for it only; the holder asks the
//    instance (HostNodeContent.measure, points; mode 0 / NaN = unconstrained, 2 = at most). The
//    instance's `invalidateSize()` re-measures the node before the next frame (FrameBatcher, the
//    text node's path) — once the runtime has asked the node's size: Yoga asserts on dirtying a
//    node without a measure func, and before the first ask the first layout measures anyway.
//  - The events go up from the instance itself (the host's channel → Core.nodeEmit), the methods
//    come down through HostUI.nodeCall to the registry: neither passes the holder.
//  - Released (onRemoved): the registry destroys the instance.
import LeCodesCore
import UIKit

public final class UINodeHost: UINode {
    /// The kind the instance was made for (the node's first `kind` write); nil before it.
    public private(set) var kind: String?
    /// The registry's instance: nil before the `kind` write, or for a kind no half registered.
    public private(set) var instance: HostNodeContent?
    /// The runtime asked this node's size: it carries a measure func, a re-measure is safe.
    private var measured = false
    /// The kinds an empty box was logged for.
    private static var unregistered: Set<String> = []

    /// The runtime decides which host node is measured (the SDK's flag): this is asked for those only.
    public override var hasMeasure: Bool { true }

    override func createView() -> UIView { HostNodeBoxView(node: self) }

    public override func setProperty(_ prop: String, _ value: String?) {
        super.setProperty(prop, value)
        if prop == "kind" {
            if kind == nil { makeInstance(value ?? "") }
            return
        }
        instance?.setProperty(prop, value)
    }

    private func makeInstance(_ kind: String) {
        self.kind = kind
        guard !kind.isEmpty, let made = rendererServices?.makeHostNode(node: id, kind: kind, invalidateSize: { [weak self] in
            self?.invalidateSize()
        }) else {
            if UINodeHost.unregistered.insert(kind).inserted {
                print("LeCodes: no host node \"\(kind)\" is registered on this host — the node is an empty box")
            }
            return
        }
        instance = made
        (view as? HostNodeBoxView)?.adopt(made.view, paintsSelf: made.paintsSelf)
    }

    // MARK: - the paint

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        guard let instance else { return }
        for s in UINodeHost.colorStyles where r.dirty(s.bit) && (!s.selfOnly || instance.paintsSelf) {
            instance.setStyle(s.name, color: r.has(s.bit) ? UIColor(rgba: r.color(s.word)) : nil)
        }
        for s in UINodeHost.numberStyles where r.dirty(s.bit) && (!s.selfOnly || instance.paintsSelf) {
            instance.setStyle(s.name, number: r.has(s.bit) ? Double(CGFloat(r.float(s.word)) / (s.density ? UINode.density : 1)) : nil)
        }
    }

    typealias B = CuiPaint.Bit
    typealias W = CuiPaint.Word
    /// NODE_STYLES of tools/cli/src/plugin/contract.ts, its colors: what a contract's `styles` may
    /// list (RendererTests holds the two lists together). `selfOnly`: painted on the box unless the
    /// instance paints itself.
    static let colorStyles: [(name: String, bit: Int, word: Int, selfOnly: Bool)] = [
        ("color", B.color, W.color, false),
        ("tintColor", B.tintColor, W.tintColor, false),
        ("placeholderColor", B.placeholderColor, W.placeholderColor, false),
        ("refreshControlColor", B.refreshControlColor, W.refreshControlColor, false),
        ("rippleColor", B.rippleColor, W.rippleColor, false),
        ("overlayColor", B.overlayColor, W.overlayColor, false),
        ("backgroundColor", B.backgroundColor, W.backgroundColor, true),
    ]
    /// …its numbers; `density`: a length, the record's px over UINode.density (logical px out).
    static let numberStyles: [(name: String, bit: Int, word: Int, density: Bool, selfOnly: Bool)] = [
        ("fontSize", B.fontSize, W.fontSize, true, false),
        ("fontWeight", B.fontWeight, W.fontWeight, false, false),
        ("lineHeight", B.lineHeight, W.lineHeight, true, false),
        ("letterSpacing", B.letterSpacing, W.letterSpacing, true, false),
        ("lineClamp", B.lineClamp, W.lineClamp, false, false),
        ("autocorrect", B.autocorrect, W.autocorrect, false, false),
        ("maxLength", B.maxLength, W.maxLength, false, false),
        ("keyboardShrink", B.keyboardShrink, W.keyboardShrink, false, false),
        ("keyboardDismiss", B.keyboardDismiss, W.keyboardDismiss, false, false),
        ("showScrollbar", B.showScrollbar, W.showScrollbar, false, false),
        ("sheetDetent", B.sheetDetent, W.sheetDetent, false, false),
        ("sheetDismissible", B.sheetDismissible, W.sheetDismissible, false, false),
        ("dim", B.dim, W.dim, false, false),
        ("backdropBlur", B.backdropBlur, W.backdropBlur, true, true),
    ]

    // MARK: - the size

    override func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        measured = true
        guard let instance else { return .zero }
        let d = UINode.density
        let w: CGFloat? = widthMode == 0 || width.isNaN ? nil : CGFloat(width) / d
        let h: CGFloat? = heightMode == 0 || height.isNaN ? nil : CGFloat(height) / d
        let size = instance.measure(width: w, widthAtMost: widthMode == 2, height: h, heightAtMost: heightMode == 2)
        return CGSize(width: size.width * d, height: size.height * d)
    }

    /// The instance's content changed size (its channel's `invalidateSize`, main thread).
    private func invalidateSize() {
        guard !isRemoved, measured else { return }
        FrameBatcher.request(self, measure: true)
    }

    // MARK: - the lifecycle

    public override func onRemoved() {
        super.onRemoved()
        guard instance != nil else { return }
        instance = nil
        rendererServices?.hostNodeReleased(node: id)
    }
}

/// The node's box: the instance's view inside at the box's bounds, the box paint (BoxPaint) on this
/// view, under it.
final class HostNodeBoxView: NodeView {
    /// The instance's view.
    private(set) weak var content: UIView?
    /// The instance paints its background and backdrop: BoxPaint leaves them.
    private(set) var paintsSelf = false

    /// The node's touch — a node with an `onTouchStart` listener (TREE_FLAG_INTERACTIVE) hears every
    /// finger that lands on it and feeds the track a listener took (TouchPipeline, a screen's calls).
    /// WATCHED (TouchWatcher): the instance's view keeps every gesture of its own, a track takes
    /// nothing from the control.
    private var touches: [Int32: TouchPosition] = [:]
    private var watcher: TouchWatcher?
    private var touchNode: Int {
        guard let node, !node.isRemoved, node.has(TreeEvents.TREE_FLAG_INTERACTIVE) else { return 0 }
        return node.id
    }

    private func watch() {
        guard watcher == nil else { return }
        let w = TouchWatcher()
        w.onDown = { [weak self] id, t in
            guard let self else { return }
            TouchPipeline.start(node: self.touchNode, pointerId: id, at: self.rootPoint(of: t), touches: &self.touches)
        }
        w.onMove = { [weak self] id, t in
            guard let self else { return }
            TouchPipeline.move(node: self.touchNode, pointerId: id, to: self.rootPoint(of: t), touches: &self.touches)
        }
        w.onUp = { [weak self] id, t in
            guard let self else { return }
            TouchPipeline.end(node: self.touchNode, pointerId: id, at: self.rootPoint(of: t), touches: &self.touches, sendClick: false)
        }
        w.onCancel = { [weak self] id in
            guard let self else { return }
            TouchPipeline.cancel(node: self.touchNode, pointerId: id, touches: &self.touches)
        }
        addGestureRecognizer(w)
        watcher = w
    }

    func adopt(_ view: UIView, paintsSelf: Bool) {
        self.paintsSelf = paintsSelf
        watch()
        content?.removeFromSuperview()
        view.removeFromSuperview()
        view.place(bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]   // the box's size, as soon as it moves
        addSubview(view)
        content = view
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content?.place(bounds)
    }
}
