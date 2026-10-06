// The pager's view — UIPager, THE screen-navigation element: sibling tabs that swipe side to side,
// each with its own navigation stack. A UIScrollView with UIKit's own paging (one tab per swipe,
// the system's settle), each TAB's page stack in a box-sized cell. The runtime owns the tabs, the
// stacks, the page lifecycle, the back-button pop AND the transitions between the pages of a
// stack (docs/tree.md "Transitions": the pager is a stage of the runtime's automaton, the
// tracks move the two pages' own transform / opacity / dim like any tween). This view's part:
//   - "content" / "select" (pagerCommand): remount from the pulls (Core.pager*) — every tab shows
//     its stack's top — and scroll to the selected tab;
//   - showPage: the page that became the top of the current tab goes into its cell, over or
//     under the page shown there, which STAYS shown;
//   - dropPage: the page that left is hidden, when the runtime says its transition landed;
//   - a committed USER swipe between tabs is reported through pagerDidSelect — EARLY, on the
//     release (the target is decided then; waiting for the scroll to land would delay onSelect
//     and the page's onOpen by the whole snap).
// Tab swiping is locked while the current tab is drilled in (depth > 1) — the horizontal gesture
// belongs to navigation then — and while a page is still leaving. A one-tab pager disables
// scrolling outright.
//
// What is shown is never re-derived mid-flight: between showPage and dropPage the page that left
// its stack's top is still on screen (`leaving`), and only the runtime says when it goes.
//
// The pop of a drilled-in tab under a finger is the SYSTEM's swipe (SystemBackSwipe, the same
// type that slides the app root): this whole view slides away over the page under the top one.
// This view answers the swipe's three questions; the node's view is the mount that holds the
// swipe with this view inside (PagerMount).
import LeCodesCore
import UIKit

/// The pager node's view: the node's box, and the back swipe's view with the pager inside.
final class PagerMount: NodeView {
    let pager: PagerView
    private let swipe: SystemBackSwipe

    init(node: UINodePager) {
        pager = PagerView(node: node)
        swipe = SystemBackSwipe(stage: pager, delegate: pager)
        pager.backSwipe = swipe
        super.init(node: node)
        clipsToBounds = true
        addSubview(swipe.view)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        swipe.view.place(bounds)
        swipe.view.layoutIfNeeded()
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha >= 0.01, isUserInteractionEnabled, self.point(inside: point, with: event) else { return nil }
        return swipe.view.hitTest(convert(point, to: swipe.view), with: event)
    }
}

final class PagerView: TouchScrollView, UIScrollViewDelegate, SystemBackSwipeDelegate {
    weak var node: UINodePager?
    private var tabCount = 0
    private var currentTab = 0
    private var mounted = false
    private var pagingLocked = false
    /// The pages shown though they are no tab's top: leaving, until the runtime drops them.
    private var leaving: [UINode] = []
    /// Pages are moving — the runtime's transition, or the system's swipe: no tab swipe, no realign.
    private var busy: Bool { !leaving.isEmpty || swiped != nil }
    /// The system's swipe over this view: told when something else takes the tab.
    weak var backSwipe: SystemBackSwipe?

    init(node: UINodePager) {
        self.node = node
        super.init(frame: .zero)
        isPagingEnabled = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bounces = false
        clipsToBounds = true
        contentInsetAdjustmentBehavior = .never
        delegate = self
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// The pager node still backs a live runtime instance: no `Core.pager*` call with a freed id
    /// (yoga recycles addresses — a pager of the NEXT screen could answer).
    private var alive: Bool { node.map { !$0.isRemoved } ?? false }
    private var id: Int { node?.id ?? 0 }
    private func pageNode(_ tab: Int, _ pos: Int) -> UINode? { Nodes[Core.pagerPageNode(id, tab: tab, pos: pos)] }
    private func stackLen(_ tab: Int) -> Int { Core.pagerStackLen(id, tab: tab) }
    private func clampTab(_ i: Int) -> Int { min(max(i, 0), max(0, tabCount - 1)) }
    private var root: UIRootHost? { UINode.appRoot as? UIRootHost }

    // MARK: - geometry: every page root at the pager's box, each in its tab cell

    /// From the node's layout visit: re-drive the runtime's page layout at the current box (pages
    /// are their own layout roots), size the content, place the cells, reconcile.
    func layoutPages() {
        guard alive, bounds.width > 0, bounds.height > 0 else { return }
        let w = bounds.width, h = bounds.height
        tabCount = Core.pagerTabCount(id)
        Core.pagerLayoutPages(id, width: Float(w), height: Float(h))
        let size = CGSize(width: CGFloat(max(1, tabCount)) * w, height: h)
        if contentSize != size { contentSize = size }
        placeCells()
        if !mounted {
            mounted = true
            currentTab = clampTab(Core.pagerSelectedIndex(id))
            contentOffset = CGPoint(x: CGFloat(currentTab) * w, y: 0)
        } else if !isDragging, !isDecelerating, !busy {
            let x = CGFloat(clampTab(currentTab)) * w   // realign after a resize
            if contentOffset.x != x { contentOffset = CGPoint(x: x, y: 0) }
        }
        reconcilePages()
    }

    private func cell(_ tab: Int) -> CGRect {
        CGRect(x: CGFloat(tab) * bounds.width, y: 0, width: bounds.width, height: bounds.height)
    }

    /// Pages by the runtime's (tab, pos) order, not the children's insertion order. Through
    /// `place`, never `frame`: this runs on every layout visit, and a page mid-transition or under
    /// the edge swipe carries a transform — a `frame` write there moved the top page a width to
    /// the left for the whole gesture, and left it there after a cancel.
    private func placeCells() {
        for tab in 0..<tabCount {
            let f = cell(tab)
            for pos in 0..<stackLen(tab) {
                // Not the page the swipe has under its finger: it sits in the swipe's page, at
                // that page's origin, and comes home to its cell when the pop is over.
                guard let page = pageNode(tab, pos), page.view.superview === self else { continue }
                if page.view.placement != f { UIView.performWithoutAnimation { page.view.place(f) } }
            }
        }
    }

    /// Each tab shows its stack's top, and a page that is leaving shows until it is dropped; a
    /// child in no stack is a keepAlive-stashed page — hidden (its removal is the runtime's).
    private func reconcilePages() {
        guard swiped == nil, alive else { return }
        tabCount = Core.pagerTabCount(id)
        leaving.removeAll { $0.isRemoved || $0.view.superview !== self }
        var shown = Set(leaving.map { ObjectIdentifier($0.view) })
        for tab in 0..<tabCount {
            let len = stackLen(tab)
            if len > 0, let top = pageNode(tab, len - 1) { shown.insert(ObjectIdentifier(top.view)) }
        }
        for v in subviews where v is NodeView { v.isHidden = !shown.contains(ObjectIdentifier(v)) }
        refreshPagingLock()
        // The runtime's page-mounted hook fires while the page root is BUILT — before its view had
        // a place. The pages have views now; a no-op once each widget is where it belongs.
        root?.updateAttachedWidgets()
    }

    private func refreshPagingLock() {
        pagingLocked = tabCount <= 1 || stackLen(currentTab) > 1
        isScrollEnabled = !pagingLocked && !busy
    }

    // MARK: - the tab swipe (UIKit pages; the report is early, on the release)

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let w = bounds.width
        guard w > 0 else { return }
        commitTab(clampTab(Int((targetContentOffset.pointee.x + w / 2) / w)))
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let w = bounds.width
        guard w > 0 else { return }
        commitTab(clampTab(Int((contentOffset.x + w / 2) / w)))   // the safety net
    }

    /// A committed USER swipe: the runtime updates the SDK's index, fires onSelect and the pages'
    /// open / close. A programmatic select set currentTab up front, so it never echoes back.
    private func commitTab(_ index: Int) {
        guard index != currentTab, alive else { return }
        root?.dismissKeyboardForNavigation()
        currentTab = index
        Core.pagerDidSelect(id, index: index)
        refreshPagingLock()
    }

    // MARK: - commands (the state is the runtime's; the change is made already)

    func handleCommand(_ cmd: String, animated: Bool) {
        guard alive else { return }
        switch cmd {
        case "select":
            root?.dismissKeyboardForNavigation()
            currentTab = clampTab(Core.pagerSelectedIndex(id))
            refreshPagingLock()
            if mounted, bounds.width > 0 {
                let x = CGFloat(currentTab) * bounds.width
                if Animations.enabled, animated { setContentOffset(CGPoint(x: x, y: 0), animated: true) }
                else { contentOffset = CGPoint(x: x, y: 0) }
            }
        case "content":
            remountPages()   // a content swap is not navigation: the keyboard stays
        default:
            break
        }
    }

    /// The pages changed wholesale: everything re-derived from the runtime, the scroll on the
    /// (already clamped) selected tab; nothing is in flight — the runtime landed its transition
    /// before it changed the content — so the runtime's tops ARE what shows.
    private func remountPages() {
        backSwipe?.callOff()
        leaving.removeAll()
        tabCount = Core.pagerTabCount(id)
        currentTab = clampTab(Core.pagerSelectedIndex(id))
        if bounds.width > 0, bounds.height > 0 {
            Core.pagerLayoutPages(id, width: Float(bounds.width), height: Float(bounds.height))
            contentSize = CGSize(width: CGFloat(max(1, tabCount)) * bounds.width, height: bounds.height)
            placeCells()
            contentOffset = CGPoint(x: CGFloat(currentTab) * bounds.width, y: 0)
        }
        reconcilePages()
    }

    // MARK: - a change of the current tab's top (HostUI.pagerShowPage / pagerDropPage)

    /// `page` is the top of the current tab now, laid out by the runtime at the pager's box: into
    /// the tab's cell, over or under the page shown there — which stays shown, the runtime moves
    /// both and drops the one that left.
    func showPage(_ page: UINode, above: Bool) {
        guard alive else { return }
        root?.dismissKeyboardForNavigation()
        // The swipe's back: the runtime answered with the page the finger revealed. The views
        // stay where the swipe has them until its pop is over (backSwipeLanded).
        if let sw = swiped, sw.asking, sw.revealed === page {
            swiped?.adopted = true
            return
        }
        backSwipe?.callOff()
        let f = cell(currentTab)
        var shown = children(in: f).filter { $0 !== page && !$0.view.isHidden }
        // While the swipe's pop lands the page it revealed is what the tab shows (its view is the
        // swipe's for now), and the page it slides away is gone.
        if let sw = swiped, sw.adopted {
            shown.removeAll { $0 === sw.top }
            if sw.revealed !== page { shown.append(sw.revealed) }
        }
        UIView.performWithoutAnimation { page.view.place(f) }
        page.view.isHidden = false
        if above { bringSubviewToFront(page.view) }
        else if let lowest = shown.first(where: { $0.view.superview === self }) { insertSubview(page.view, belowSubview: lowest.view) }
        page.updateLayout()
        for old in shown where !leaving.contains(where: { $0 === old }) { leaving.append(old) }
        refreshPagingLock()
        root?.updateAttachedWidgets()
    }

    /// `page` left the top of its tab and its transition has landed: hidden. (The page the swipe
    /// is still sliding away goes when its pop is over.)
    func dropPage(_ page: UINode) {
        if let sw = swiped, sw.top === page { return }
        leaving.removeAll { $0 === page }
        reconcilePages()
    }

    /// The page nodes whose view sits in the cell `f`, bottom to top.
    private func children(in f: CGRect) -> [UINode] {
        guard let node else { return [] }
        return subviews.compactMap { v in v.placement == f ? node.children.first { $0.view === v } : nil }
    }

    /// The runtime released the page `child` (removeNode): may its view go now? Not while the
    /// swipe is still sliding it away — the end of its pop removes it.
    func releases(_ child: UINode) -> Bool {
        guard let sw = swiped, sw.top === child else {
            leaving.removeAll { $0 === child }
            return true
        }
        swiped?.released = true
        return false
    }

    /// Is `page`'s view this pager's — in a cell, or under the swipe for the moment?
    func holds(_ page: UINode) -> Bool { page.view.superview === self || swiped?.revealed === page }

    // MARK: - the system's back swipe over a drilled-in tab (SystemBackSwipeDelegate)

    /// The two pages of a swipe, and what the runtime has said of them.
    private struct Swiped {
        let revealed: UINode
        let top: UINode
        var asking = false     // the back chain is running: a showPage naming `revealed` is its answer
        var adopted = false    // the runtime popped to `revealed`
        var released = false   // the runtime released `top`: its view goes when the pop is over
    }
    private var swiped: Swiped?

    /// A swipe begins when the runtime says a back pops THIS pager. A transition in flight lands
    /// first, and what the landing wrote reaches the views now; the page under the top one goes
    /// into the swipe's page, at this view's size.
    func backSwipeReveals(in page: UIView) -> Bool {
        guard alive, mounted, swiped == nil, bounds.width > 0, case .pager(let named) = Core.backTarget(), named == id else { return false }
        Core.settleTransitions()
        FrameBatcher.runTick()
        let len = stackLen(currentTab)
        guard leaving.isEmpty, len > 1, let top = pageNode(currentTab, len - 1), let under = pageNode(currentTab, len - 2),
              under.view.superview === self else { return false }
        swiped = Swiped(revealed: under, top: top)
        isScrollEnabled = false
        page.backgroundColor = under.paint.backgroundColor.map { UIColor(rgba: $0) } ?? .black
        under.view.isHidden = false
        UIView.performWithoutAnimation { under.view.place(CGRect(origin: .zero, size: bounds.size)) }
        page.addSubview(under.view)
        under.updateLayout()
        return true
    }

    /// The back is made: the chain the button runs, with no transition of the runtime's — the
    /// gesture was it. true = the runtime popped this tab to the revealed page.
    func backSwipeReleased() -> Bool {
        guard swiped != nil else { return false }
        swiped?.asking = true
        _ = Core.backCommitted()
        swiped?.asking = false
        return swiped?.adopted ?? false
    }

    /// The pop is over: the revealed page comes home, into its cell under everything, and the
    /// page the swipe slid away goes if the runtime released it. What shows is the runtime's tops
    /// and the pages still leaving, as ever.
    func backSwipeLanded(taken: Bool) {
        guard let sw = swiped else { return }
        swiped = nil
        if let node, node.children.contains(where: { $0 === sw.revealed }), !sw.revealed.isRemoved {
            UIView.performWithoutAnimation { sw.revealed.view.place(cell(currentTab)) }
            insertSubview(sw.revealed.view, at: 0)
        } else {
            sw.revealed.view.removeFromSuperview()
        }
        if sw.released { sw.top.view.removeFromSuperview() }
        guard alive else { return }
        reconcilePages()
        if taken { sw.revealed.updateLayout() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { backSwipe?.callOff() }
    }
}
