// The node classes with a view of their own kind: the screen, the text, the button, the image. A
// container (column / row / box / scrollable-until-its-step / spacer) is UINodeContainer over a
// plain NodeView. Each class turns its part of the paint record into view state and answers the
// core's measure where it is a measured leaf.
import LeCodesCore
import UIKit

public final class UINodeScreen: UINodeContainer {
    override func createView() -> UIView { ScreenView(node: self) }

    /// Black over the screen, 0…1 — the pose of the screen under the other one in a transition.
    public private(set) var dim: CGFloat = 0

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        if r.dirty(CuiPaint.Bit.dim) {
            dim = CGFloat(r.float(CuiPaint.Word.dim))
            (view as? ScreenView)?.setDim(dim)
        }
        if r.dirty(CuiPaint.Bit.backgroundColor) { (UINode.appRoot as? UIRootHost)?.screenBackgroundChanged(self) }
    }
}

public final class UINodeButton: UINodeContainer {
    override func createView() -> UIView { ButtonView(node: self) }
    var isPressed: Bool { (view as? ButtonView)?.isPressedNow ?? false }
}

public final class UINodeText: UINode {
    private(set) var fontSize: CGFloat = 14
    private var fontWeight = 400
    private var italic = false
    private var fontFamily = ""
    var label: TextLabel { (view as! TextView).label }

    public override init(id: Int, type: String) {
        super.init(id: id, type: type)
        TextNodes.add(self)
    }
    override func createView() -> UIView { TextView(node: self) }
    public override var hasMeasure: Bool { true }

    public override func setProperty(_ prop: String, _ value: String?) {
        super.setProperty(prop, value)
        if prop == "text" {
            label.content = value ?? ""
            FrameBatcher.request(self, measure: true)
        }
    }

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        let l = label
        var fontChanged = false
        if r.dirty(B.color) { l.textColor = r.has(B.color) ? UIColor(rgba: r.color(W.color)) : .white }
        if r.dirty(B.fontSize) { fontSize = CGFloat(r.float(W.fontSize)); fontChanged = true }
        if r.dirty(B.fontWeight) { fontWeight = Int(r.float(W.fontWeight)); fontChanged = true }
        if r.dirty(B.fontStyle) { italic = r.word(W.fontStyle) == CuiPaint.FontStyle.italic.rawValue; fontChanged = true }
        if r.dirty(B.fontFamily) { fontFamily = r.has(B.fontFamily) ? r.string(W.fontFamily) : ""; fontChanged = true }
        if r.dirty(B.lineHeight) { l.lineHeight = CGFloat(r.float(W.lineHeight)) }
        if r.dirty(B.letterSpacing) { l.letterSpacing = CGFloat(r.float(W.letterSpacing)) }
        if r.dirty(B.textAlign) {
            switch CuiPaint.TextAlign(rawValue: r.word(W.textAlign)) ?? .start {
            case .center: l.textAlignment = .center
            case .end, .right: l.textAlignment = .right
            case .start, .left: l.textAlignment = .left
            }
        }
        if r.dirty(B.textDecoration) {
            let d = CuiPaint.TextDecoration(rawValue: r.word(W.textDecoration)) ?? .none
            l.underline = d == .underline
            l.strikethrough = d == .line_through
        }
        if r.dirty(B.lineClamp) { l.lineClamp = max(0, Int(r.float(W.lineClamp))) }
        if r.dirty(B.textOverflow) { l.clipsOverflow = CuiPaint.TextOverflow(rawValue: r.word(W.textOverflow)) == .clip }
        if fontChanged { resolveFont() }
        if r.dirty(B.fontSize) || r.dirty(B.fontWeight) || r.dirty(B.fontStyle) || r.dirty(B.fontFamily) || r.dirty(B.lineHeight)
            || r.dirty(B.letterSpacing) || r.dirty(B.lineClamp) || r.dirty(B.textOverflow) {
            FrameBatcher.request(self, measure: true)
        } else if r.anyDirty {
            label.setNeedsDisplay()
        }
    }

    private func resolveFont() {
        label.resolvedFont = FontManager.font(family: fontFamily, weight: fontWeight, italic: italic, size: fontSize)
    }

    /// A face landed (FontManager): re-resolve, re-measure.
    func fontChanged() {
        resolveFont()
        FrameBatcher.request(self, measure: true)
    }

    override func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        label.measure(width: width, widthMode: widthMode, height: height, heightMode: heightMode)
    }

    /// The padding is the core's: the label draws inside it.
    override func frameApplied() {
        let p = CreatorUI.padding(id)
        label.inset = UIEdgeInsets(top: CGFloat(p.top), left: CGFloat(p.left), bottom: CGFloat(p.bottom), right: CGFloat(p.right))
    }

    public override func onRemoved() {
        super.onRemoved()
        TextNodes.remove(self)
    }
}

public final class UINodeImage: UINode {
    private var imageView: ImageView { view as! ImageView }
    /// The one tint (the source's own through the core's cascade): applies to SVG only.
    private(set) var tintColor: UInt32?

    override func createView() -> UIView { ImageView(node: self) }
    public override var hasMeasure: Bool { true }

    public override func setProperty(_ prop: String, _ value: String?) {
        super.setProperty(prop, value)
        switch prop {
        case "src": setSource(value ?? "")
        case "sourceRect":
            let parts = (value ?? "").split(separator: " ").compactMap { Double($0) }
            imageView.sourceRect = parts.count == 4 ? CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) : nil
            imageView.applySourceRectCrop()
            FrameBatcher.request(self, measure: true)
        default: break
        }
    }

    private func setSource(_ src: String) {
        let v = imageView
        if src.hasPrefix("canvas:") {
            // A baked _creatorCanvas surface (UIImage(canvas)): the painter host's pixels, bound so a
            // later Canvas.update() repaints this node in place.
            if let id = Int32(src.dropFirst(7)) { v.setCanvas(id) } else { v.unbindCanvas(); v.setImage(nil) }
            return
        }
        v.unbindCanvas()   // every other source drops the binding
        if src.hasPrefix("scene2d:") {
            // A LIVE 2D scene as the source: the engine draws it under the view every frame.
            if let id = Int32(src.dropFirst(8)) { v.setScene2d(id) } else { v.unbindScene2d(); v.setImage(nil) }
            return
        }
        v.unbindScene2d()
        if src.isEmpty { v.setImage(nil); return }
        if src.hasPrefix("id:") {
            let data = Int(src.dropFirst(3)).flatMap { rendererServices?.buffer(id: $0) }
            // An SVG file (an asset, a fetched .svg) draws through the core like "svg:" markup — the
            // same sniffing the runtime does for canvas images.
            if let data, SvgDocument.looksLikeSvg(data) { v.setSvg(String(decoding: data, as: UTF8.self)) }
            else { v.setImage(data.flatMap { UIImage(data: $0) }) }
        } else if src.hasPrefix("svg:") {
            v.setSvg(String(src.dropFirst(4)))
        } else {
            v.load(url: src)
        }
    }

    /// Canvas.update() on the surface this node shows (CanvasSurfaces).
    func refreshCanvasSurface(_ surfaceId: Int32) { imageView.refreshCanvasSurface(surfaceId) }

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        if r.dirty(B.objectFit) { imageView.setObjectFit(CuiPaint.ObjectFit(rawValue: r.word(W.objectFit)) ?? .contain) }
        if r.dirty(B.tintColor) {
            tintColor = r.has(B.tintColor) ? r.color(W.tintColor) : nil
            imageView.setTint(tintColor)
        }
    }

    override func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        imageView.measure(width: width, widthMode: widthMode, height: height, heightMode: heightMode)
    }

    public override func onRemoved() {
        super.onRemoved()
        imageView.cancelLoad()
        imageView.unbindCanvas()
        imageView.unbindScene2d()
    }
}

/// A widget root: a screen-like root shown over (or inside) its owner, with an optional scrim
/// behind it (`overlayColor`: a sibling view directly behind the widget, tapped → OVERLAY_TAP)
/// and, for a bottom sheet (`sheetDetents`), the sheet behavior. The behavior lives on the NODE:
/// styles arrive before the widget is mounted. Style order is not guaranteed — `sheetDetent` /
/// `sheetDismissible` may arrive before `sheetDetents` creates the behavior; parked and consumed.
public final class UINodeWidget: UINodeContainer {
    public private(set) var overlayColor: UInt32?
    public private(set) var overlay: WidgetOverlayView?
    public private(set) var sheet: WidgetSheetBehavior?
    private var pendingSheetDetent = 0
    private var pendingSheetDismissible = true

    override func createView() -> UIView { WidgetView(node: self) }

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        if r.dirty(B.overlayColor) {
            overlayColor = r.has(B.overlayColor) ? r.color(W.overlayColor) : nil
            if overlayColor == nil { removeOverlay() } else { applyOverlay() }
        }
        if r.dirty(B.sheetDetents) { setSheetDetents(r.string(W.sheetDetents)) }
        if r.dirty(B.sheetDetent) { setSheetDetent(Int(r.float(W.sheetDetent))) }
        if r.dirty(B.sheetDismissible) { setSheetDismissible(r.bool(W.sheetDismissible)) }
    }

    // MARK: - the scrim

    /// Create / recolor the scrim once the widget's view has a parent: directly behind it.
    public func applyOverlay() {
        guard let color = overlayColor, let parent = view.superview else { return }
        if let o = overlay, o.superview !== parent { o.removeFromSuperview(); overlay = nil }
        let o = overlay ?? {
            let v = WidgetOverlayView(widget: self)
            overlay = v
            return v
        }()
        o.backgroundColor = UIColor(rgba: color)
        o.place(parent.bounds)
        o.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if o.superview !== parent { parent.insertSubview(o, belowSubview: view) }
    }

    public func removeOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// Above the owner's content, the scrim directly behind, whatever order the views were added.
    public func bringToFront() {
        guard let parent = view.superview else { return }
        if let overlay, overlay.superview === parent { parent.bringSubviewToFront(overlay) }
        parent.bringSubviewToFront(view)
    }

    // MARK: - the sheet

    private func setSheetDetents(_ value: String) {
        let list = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }.map { CGFloat($0) }.sorted()
        guard !list.isEmpty else { return }
        if let sheet { sheet.detents = list; return }
        let behavior = WidgetSheetBehavior(widget: self)
        behavior.detents = list
        behavior.dismissible = pendingSheetDismissible
        sheet = behavior
        behavior.setDetent(pendingSheetDetent, animated: false)
        if lastLayout != nil { behavior.layoutDidApply() }   // already laid out (the style arrived after the show)
    }
    private func setSheetDetent(_ index: Int) {
        if let sheet { sheet.setDetent(index, animated: true) } else { pendingSheetDetent = index }
    }
    private func setSheetDismissible(_ value: Bool) {
        if let sheet { sheet.dismissible = value } else { pendingSheetDismissible = value }
    }

    /// The walk visited the widget: the sheet re-composes its offset; the first valid layout plays
    /// the entrance. Outside the walk's dedupe on purpose (a pass reporting "unchanged" still owes it).
    override func layoutVisited() {
        sheet?.layoutDidApply()
    }

    public override func onRemoved() {
        super.onRemoved()
        removeOverlay()
    }
}

/// A scrollable container ("scrollable", "scrollableScreen"): the scroll-side of the paint record
/// onto its ScrollContainerView, the scroll events gated on the flags, the content size after
/// every layout visit.
public class UINodeScrollable: UINodeContainer {
    var scrollView: ScrollContainerView { view as! ScrollContainerView }
    override func createView() -> UIView { ScrollContainerView(node: self) }

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        let v = scrollView
        if r.dirty(B.scrollDirection) {
            switch CuiPaint.ScrollDirection(rawValue: r.word(W.scrollDirection)) ?? .vertical {
            case .vertical: v.axis = .vertical
            case .horizontal: v.axis = .horizontal
            case .all: v.axis = .both
            }
        }
        if r.dirty(B.overscrollMode) {
            switch CuiPaint.OverscrollMode(rawValue: r.word(W.overscrollMode)) {
            case .none?: v.overscrollMode = .none
            case .absorb?: v.overscrollMode = .absorb
            default: v.overscrollMode = .bounce
            }
        }
        if r.dirty(B.snap) {
            switch CuiPaint.Snap(rawValue: r.word(W.snap)) {
            case .start?: v.snapAlign = .start
            case .center?: v.snapAlign = .center
            case .end?: v.snapAlign = .end
            default: v.snapAlign = .none
            }
        }
        if r.dirty(B.showScrollbar) {
            let show = r.bool(W.showScrollbar)
            v.showsVerticalScrollIndicator = show
            v.showsHorizontalScrollIndicator = show
        }
        if r.dirty(B.keyboardDismissMode) {
            switch CuiPaint.KeyboardDismissMode(rawValue: r.word(W.keyboardDismissMode)) {
            case .scroll?: v.keyboardDismissMode = .onDrag
            case .none?: v.keyboardDismissMode = .none
            default: v.keyboardDismissMode = .interactive
            }
        }
        if r.dirty(B.refreshControlColor) { v.refreshTint = r.has(B.refreshControlColor) ? UIColor(rgba: r.color(W.refreshControlColor)) : nil }
    }

    public override func flagsChanged() {
        scrollView.setRefreshEnabled(has(TreeEvents.TREE_FLAG_REFRESH))
    }

    override func layoutFinished() {
        scrollView.updateContentSize()
    }

    // MARK: - the host's keyboard (KeyboardLayoutController)

    /// The scroll view itself (its offset, insets and content size, read by the host).
    public var scroll: UIScrollView { scrollView }
    public var isVertical: Bool { scrollView.axis == .vertical }
    /// Native inset mode: the keyboard's band as this view's bottom contentInset — the frame stays
    /// under the keyboard, no relayout; a clear that lands mid-gesture waits for the settle.
    public func setKeyboardInset(_ inset: CGFloat) { scrollView.setKeyboardInset(inset) }
    public func clearKeyboardInset() { scrollView.clearKeyboardInset() }
    public var keyboardInset: CGFloat { scrollView.contentInset.bottom }
    /// Scroll so `view` (a descendant) is visible above the keyboard band, `margin` pt of room.
    public func reveal(_ view: UIView, margin: CGFloat = 24) {
        guard view.isDescendant(of: scrollView) else { return }
        scrollView.reveal(view.convert(view.bounds, to: scrollView), margin: margin)
    }

    // The scroll events by id, gated on the flag mask.
    func onScroll(_ offset: CGFloat) {
        if has(TreeEvents.TREE_FLAG_SCROLL) { Core.nodeScroll(id, scrollTop: Float(offset)) }
    }
    func onOverscroll(_ value: CGFloat) {
        if has(TreeEvents.TREE_FLAG_OVERSCROLL) { Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_OVERSCROLL, [.double(Double(value))]) }
    }
    func onScrollRelease() {
        if has(TreeEvents.TREE_FLAG_SCROLL_RELEASE) { Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_SCROLL_RELEASE) }
    }
}

/// The virtualized list: the core's window over a VListView. Its children are the mounted items
/// (the runtime's insertNode / removeNode with this node as the parent), detached yoga roots the
/// core places by offset; every layout visit drives vlistUpdateLayout FIRST (it may mount /
/// unmount and refresh the height cache), then the content height, then the items, then a
/// pending anchored scroll.
public final class UINodeVList: UINodeScrollable {
    private var list: VListView { view as! VListView }
    override func createView() -> UIView { VListView(node: self) }

    override func layoutVisited() {
        CreatorUI.vlistUpdateLayout(id)
    }
    override func layoutFinished() {
        list.updateContentSize()
        list.placeItems()
        list.applyPendingScroll()
    }

    /// A row's box: the core's offset of its item root, then the row's own box inside that root —
    /// its margins, its alignSelf (NaN = not mounted yet: keep the y).
    func placeRow(_ row: UINode, box r: CGRect) {
        let top = CGFloat(CreatorUI.vlistItemOffset(id, itemRoot: row.id))
        let y = top.isFinite ? top + r.minY : row.view.placement.minY
        row.box.applyFrame(CGRect(x: r.minX, y: y, width: r.width, height: r.height))
    }

    /// HostUI.vlistScroll.
    func applyScroll(_ y: CGFloat, animated: Bool) {
        if animated {
            list.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        } else {
            list.pendingScrollY = y
            FrameBatcher.request(self)
        }
    }
}

/// The pager: its children are its PAGES (screen roots the runtime attaches through insertNode,
/// tab-major), placed by PagerView in tab cells; the runtime owns the tabs, the stacks and the
/// page lifecycle, this node only routes.
public final class UINodePager: UINodeContainer {
    /// The node's view is the mount — the box, and the system's back swipe over the pager
    /// inside it (PagerMount); the pages sit in the pager's own view.
    var pagerView: PagerView { (view as! PagerMount).pager }
    override func createView() -> UIView { PagerMount(node: self) }

    /// The page the pager shows now: the top of the selected tab, straight from the runtime.
    public var currentPage: UINode? {
        let tabs = Core.pagerTabCount(id)
        guard tabs > 0 else { return nil }
        let tab = min(max(Core.pagerSelectedIndex(id), 0), tabs - 1)
        let len = Core.pagerStackLen(id, tab: tab)
        guard len > 0 else { return nil }
        return Nodes[Core.pagerPageNode(id, tab: tab, pos: len - 1)]
    }

    /// Is `node` a page of a live pager (its view sits in the pager's view)? The owner a widget
    /// attached to a page mounts into — for EVERY tab, not just the one on screen.
    public static func isLivePage(_ node: UINode) -> Bool {
        guard let pager = node.parent as? UINodePager, !pager.isRemoved, !node.isRemoved else { return false }
        return pager.pagerView.holds(node)
    }
    /// Is `node` the page its pager shows?
    public static func isCurrentPage(_ node: UINode) -> Bool {
        guard let pager = node.parent as? UINodePager, !pager.isRemoved else { return false }
        return pager.currentPage === node
    }

    /// The pager's view takes its size from the mount through UIKit's own layout: made now, the
    /// pages are placed against the box this pass gave.
    override func layoutVisited() {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        pagerView.layoutPages()
    }

    /// A page's view goes under the pager's view, in the children's order.
    override func childInserted(_ child: UINode) {
        let i = children.firstIndex { $0 === child } ?? 0
        let pager = pagerView
        if i > 0, children[i - 1].view.superview === pager { pager.insertSubview(child.view, aboveSubview: children[i - 1].view) }
        else { pager.insertSubview(child.view, at: 0) }
        FrameBatcher.request(self)
    }

    /// A released page's view goes — unless the pager's view is still sliding it away.
    override func childRemoved(_ child: UINode) {
        if pagerView.releases(child) { super.childRemoved(child) } else { FrameBatcher.request(self) }
    }
}

/// An input ("input": one line, "textarea": auto-growing): the value and the focus over the
/// content channel, the traits from the paint record, the events by id gated on the flags,
/// posted; the keyboard policies the keyboard step reads.
public final class UINodeInput: UINode {
    public let multiline: Bool
    private var control: InputControl { view as! InputControl }
    private(set) var fontSize: CGFloat = 14
    private var fontWeight = 400
    private var italic = false
    private var fontFamily = ""
    private var placeholderText: String?
    private var placeholderColor: UIColor?
    /// The keyboard policies (keyboardShrink / keyboardDismiss): who is focused decides.
    public private(set) var keyboardShrink = true
    public private(set) var keyboardDismiss = true
    public private(set) var isFocused = false

    public override init(id: Int, type: String) {
        multiline = type == "textarea"
        super.init(id: id, type: type)
        TextNodes.add(self)
    }
    override func createView() -> UIView { multiline ? TextAreaView(node: self) : InputFieldView(node: self) }
    public override var hasMeasure: Bool { true }

    /// The live text (HostUI.getTextValue): canonical for the picker kinds.
    public var textValue: String { control.textValue }

    public override func setProperty(_ prop: String, _ value: String?) {
        super.setProperty(prop, value)
        switch prop {
        case "value": control.setValue(value ?? "")
        case "focus": control.setFocused(value == "1")
        case "placeholder": placeholderText = value; control.applyPlaceholder(placeholderText, color: placeholderColor)
        default: break
        }
    }

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        typealias B = CuiPaint.Bit
        typealias W = CuiPaint.Word
        let c = control
        var fontChanged = false
        if r.dirty(B.color) { c.applyTextColor(r.has(B.color) ? UIColor(rgba: r.color(W.color)) : InputDefaults.textColor) }
        if r.dirty(B.fontSize) { fontSize = CGFloat(r.float(W.fontSize)); fontChanged = true }
        if r.dirty(B.fontWeight) { fontWeight = Int(r.float(W.fontWeight)); fontChanged = true }
        if r.dirty(B.fontStyle) { italic = r.word(W.fontStyle) == CuiPaint.FontStyle.italic.rawValue; fontChanged = true }
        if r.dirty(B.fontFamily) { fontFamily = r.has(B.fontFamily) ? r.string(W.fontFamily) : ""; fontChanged = true }
        if r.dirty(B.textAlign) {
            switch CuiPaint.TextAlign(rawValue: r.word(W.textAlign)) ?? .start {
            case .center: c.applyTextAlign(.center)
            case .end, .right: c.applyTextAlign(.right)
            case .start, .left: c.applyTextAlign(.left)
            }
        }
        if r.dirty(B.lineHeight) {
            c.applyLineHeight(CGFloat(r.float(W.lineHeight)))
            FrameBatcher.request(self, measure: true)
        }
        if r.dirty(B.placeholder) { placeholderText = r.has(B.placeholder) ? r.string(W.placeholder) : nil; c.applyPlaceholder(placeholderText, color: placeholderColor) }
        if r.dirty(B.placeholderColor) { placeholderColor = r.has(B.placeholderColor) ? UIColor(rgba: r.color(W.placeholderColor)) : nil; c.applyPlaceholder(placeholderText, color: placeholderColor) }
        if r.dirty(B.type) { c.applyInputType(CuiPaint.InputType(rawValue: r.word(W.type)) ?? .text) }
        if r.dirty(B.enterKey) { c.applyEnterKey(r.has(B.enterKey) ? CuiPaint.EnterKey(rawValue: r.word(W.enterKey)) : nil) }
        if r.dirty(B.maxLength) { let m = Int(r.float(W.maxLength)); c.maxLength = m > 0 ? m : nil }
        if r.dirty(B.autocapitalize) { c.applyAutocapitalize(CuiPaint.Autocapitalize(rawValue: r.word(W.autocapitalize)) ?? .sentences) }
        if r.dirty(B.autocorrect) { c.applyAutocorrect(r.bool(W.autocorrect)) }
        if r.dirty(B.keyboardShrink) { keyboardShrink = r.bool(W.keyboardShrink) }
        if r.dirty(B.keyboardDismiss) { keyboardDismiss = r.bool(W.keyboardDismiss) }
        if fontChanged {
            c.applyFont(FontManager.font(family: fontFamily, weight: fontWeight, italic: italic, size: fontSize))
            FrameBatcher.request(self, measure: true)
        }
    }

    func fontChanged() {
        control.applyFont(FontManager.font(family: fontFamily, weight: fontWeight, italic: italic, size: fontSize))
        FrameBatcher.request(self, measure: true)
    }

    override func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        control.measure(width: width, widthMode: widthMode, height: height, heightMode: heightMode)
    }

    /// The padding is the core's: the control draws inside it.
    override func frameApplied() {
        let p = CreatorUI.padding(id)
        control.padding = UIEdgeInsets(top: CGFloat(p.top), left: CGFloat(p.left), bottom: CGFloat(p.bottom), right: CGFloat(p.right))
    }

    // MARK: - the events (posted: outside the editing transaction)

    func dispatchChange(_ value: String) {
        guard !isRemoved, has(TreeEvents.TREE_FLAG_CHANGE) else { return }
        let id = id
        JSThread.post { Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_CHANGE, [.string(value)]) }
    }
    func dispatchSubmit(_ value: String) {
        guard !isRemoved, has(TreeEvents.TREE_FLAG_SUBMIT) else { return }
        let id = id
        JSThread.post { Core.nodeEvent(id, kind: TreeEvents.TREE_EVENT_SUBMIT, [.string(value)]) }
    }
    /// The control reports its focus here (the UIKit delegate; a test without a window, where no
    /// first responder exists, drives it directly). The core's focused layer flips synchronously
    /// (a style may depend on it); the root host (the keyboard policy) hears it now, the
    /// listeners posted.
    public func focusChanged(_ focused: Bool) {
        guard !isRemoved else { return }
        isFocused = focused
        CreatorUI.setNodeFocused(id, focused)
        let root = UINode.appRoot as? UIRootHost
        if focused { root?.onInputFocused(self) } else { root?.onInputBlurred(self) }
        let kind = focused ? TreeEvents.TREE_EVENT_FOCUS : TreeEvents.TREE_EVENT_BLUR
        guard has(focused ? TreeEvents.TREE_FLAG_FOCUS : TreeEvents.TREE_FLAG_BLUR) else { return }
        let id = id
        JSThread.post { Core.nodeEvent(id, kind: kind) }
    }

    public override func onRemoved() {
        super.onRemoved()
        TextNodes.remove(self)
    }
}

