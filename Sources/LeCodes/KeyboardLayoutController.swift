// Everything the soft keyboard does to the layout, for one LeCodesView — the twin of
// hosts/android's KeyboardLayoutController.kt, carrying the old host's two modes: the keyboard's
// overlap from the notifications, the focused-root SHRINK, the NATIVE INSET mode, the safe-inset
// collapse inside the shrunk root, the tap-outside and navigation dismissal, and keeping the
// focused field scrolled into view.
//
// Focused-root shrink (docs/scroll-forms-plan.md): the keyboard shrinks EXACTLY the layout root
// that owns the focused input. A pager page shrinks while the shell and its tab bar keep their
// geometry and are covered; a widget shrinks only when the focused input is its own (bottom
// sheets rise, centered dialogs re-center); an input in a plain screen shrinks the screen.
// Everything else stays where it is — the rule native bottom bars follow. The choice is
// published to the runtime (Core.setShrunkRoot): its per-frame layout pass lays every root out
// itself, so a host-side recalc alone would be stomped by the next tick.
//
// Native inset mode — how UIKit apps avoid the keyboard: when the focused input sits inside a
// vertical scrollable whose bottom edge reaches its root's bottom, the scrollable is never
// compressed; it keeps its frame under the keyboard and gets a bottom contentInset. Its content
// is already rendered behind the keyboard, so showing, hiding and the `.interactive` drag-to-
// dismiss need no relayout at all. Everything else (a chat composer below a list, widgets,
// inputs outside scrollables) takes the shrink.
import LeCodesCore
import LeCodesUIKit
import UIKit

final class KeyboardLayoutController {
    private unowned let host: LeCodesView

    /// The keyboard's overlap with the root view's bottom edge, points; 0 with none. Written only
    /// by the keyboard notifications (and the test entry).
    private(set) var keyboardInset: CGFloat = 0
    /// Per-input policy: whichever input holds focus decides whether the layout shrinks
    /// (keyboardShrink) and whether a tap outside dismisses (keyboardDismiss: false = a chat composer).
    private(set) var activeInputShrink = true {
        didSet { if oldValue != activeInputShrink, keyboardInset > 0 { applyKeyboardLayout() } }
    }
    private(set) var activeInputDismiss = true
    /// The height the keyboard steals from the layout right now. Every "available height" consumer
    /// reads this, never keyboardInset: one missed consumer makes the layout fight the shrink.
    var effectiveInset: CGFloat { activeInputShrink ? keyboardInset : 0 }

    /// The input holding focus. Its layout root is the ONLY root the keyboard shrinks.
    private(set) weak var activeInput: UINodeInput?
    /// The root laid out with a keyboard overlap, and by how much.
    private(set) weak var shrunkRoot: UINode?
    private(set) var shrunkOverlap: CGFloat = 0
    /// The scrollable carrying the keyboard's bottom contentInset (native inset mode).
    private(set) weak var insetScrollable: UINodeScrollable?

    /// The window's real safe insets (the host writes them). The shrunk root's bottom collapse
    /// never touches the globals: it is a per-root override, restoring the root hands it the
    /// real bottom again.
    private var realSafeInsets = UIEdgeInsets.zero
    private var lastEmittedHeight: Float = 0
    private var observers: [NSObjectProtocol] = []
    /// The reveal runs after the layout pass that applies the shrink (the field's position is
    /// not final before it); the pass animates with the keyboard when it asked to.
    private var pendingReveal = false
    private var pendingAnimation: (duration: TimeInterval, curve: UIView.AnimationOptions)?

    init(host: LeCodesView) { self.host = host }
    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    /// Once, from the host's initializer: the notifications. willChangeFrame catches a keyboard
    /// kind change (emoji, the predictive bar) that shows no hide / show pair.
    func start() {
        guard observers.isEmpty else { return }
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification, UIResponder.keyboardWillChangeFrameNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.keyboardWillChange(note)
            })
        }
    }

    // MARK: - the notifications

    private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo, let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curveRaw = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        // The end frame is in screen coordinates: the overlap is measured in the ROOT VIEW's space,
        // so an embedded viewer that does not fill the window measures its own band. A hidden
        // keyboard's frame starts at the screen's bottom edge: overlap 0.
        let inWindow = host.window.map { $0.convert(end, from: nil) } ?? end
        let inHost = host.convert(inWindow, from: nil)
        let inset = min(max(0, host.bounds.maxY - inHost.minY), host.bounds.height)
        setKeyboardInset(inset, duration: duration, curve: UIView.AnimationOptions(rawValue: curveRaw << 16))
    }

    /// The keyboard's overlap changed (a notification, or a test driving it): the pull, the event,
    /// the layout — applied ONCE, at the next layout pass, animated along the keyboard's curve.
    func setKeyboardInset(_ inset: CGFloat, duration: TimeInterval, curve: UIView.AnimationOptions) {
        guard inset != keyboardInset else { return }
        keyboardInset = inset
        emitKeyboardInset(durationMs: duration * 1000)
        if duration > 0 { pendingAnimation = (duration, curve) }
        applyKeyboardLayout()
    }

    /// The keyboard's RAW overlap to the bundle (docs/input-upgrades-plan.md §7): keyboardInset,
    /// not effectiveInset, so a composer with keyboardShrink: false still learns the size while its
    /// layout stays put. The pull first, then the event — a handler reading app.keyboardHeight
    /// must agree with the event it handles.
    private func emitKeyboardInset(durationMs: Double) {
        let height = Float(keyboardInset)
        guard height != lastEmittedHeight else { return }
        lastEmittedHeight = height
        host.engine?.keyboardHeight = height
        Core.emitKeyboardEvent(height: height, duration: Float(durationMs))
    }

    // MARK: - focus

    /// Focus gained: the policies, a re-target when the keyboard is already up (enterKey: "next",
    /// a tap on another field — no notification fires for those), the reveal.
    func onInputFocused(_ input: UINodeInput) {
        let previous = activeInput
        activeInput = input
        activeInputDismiss = input.keyboardDismiss
        activeInputShrink = input.keyboardShrink   // may itself re-apply the layout
        if previous !== input, keyboardInset > 0 { applyKeyboardLayout() }
        revealFocusedInput()
    }

    /// Focus lost. The root stays shrunk on purpose: an enterKey: "next" chain drops focus for a
    /// moment between fields, and restoring + re-shrinking there would make the form jump. The
    /// keyboard's hide is what actually restores it.
    func onInputBlurred(_ input: UINodeInput) {
        if activeInput === input { activeInput = nil }
    }

    /// The layout root that owns the focused input, by the tree: the innermost of the presented
    /// screen, an open widget root, a live pager page (the walk goes outward from the input, so a
    /// page inside a widget resolves to the page).
    func focusedRoot() -> UINode? {
        var n: UINode? = activeInput
        while let cur = n {
            if isRoot(cur) { return cur }
            n = cur.parent
        }
        return nil
    }
    private func isRoot(_ node: UINode) -> Bool {
        host.currentScreen === node || host.widgetHost.contains(node) || UINodePager.isLivePage(node)
    }

    /// The view a root's keyboard overlap is measured against: the root view for the screen, the
    /// container a widget is mounted in (a `bottom: 0` sheet's own view sits near the bottom edge
    /// while it is laid out in the full container — measuring the sheet would blow the overlap
    /// up), a page's cell-sized view.
    private func region(of root: UINode) -> UIView {
        if host.currentScreen === root { return host }
        if host.widgetHost.contains(root) { return host.widgetHost.hostOf(root) ?? host }
        return root.view
    }

    /// How much of `root` the keyboard covers. A pager page whose bottom sits above a tab bar
    /// overlaps less than the raw inset; a root that reaches the window bottom by exactly it.
    private func overlap(of root: UINode) -> CGFloat {
        let region = region(of: root)
        let fullHeight = region.bounds.height
        guard fullHeight > 0 else { return keyboardInset }
        let bottomInHost = region.convert(region.bounds, to: host).maxY
        let keyboardTop = host.bounds.height - keyboardInset
        return min(max(0, bottomInHost - keyboardTop), fullHeight)
    }

    /// Forget the shrink, in the runtime too: it only compares the pointer, but the allocator hands
    /// the same address to the next root, and a stale match would lay that one out short.
    private func clearShrunkRoot() {
        shrunkRoot = nil
        shrunkOverlap = 0
        Core.setShrunkRoot(0, overlap: 0)
    }

    /// A root is being freed (a closed widget, a released page): the shrink lets go of it NOW —
    /// the keyboard's hide lands a frame or two later, and re-resolving against the dead root
    /// walks freed memory.
    func onRootReleased(_ root: UINode) {
        if shrunkRoot === root { clearShrunkRoot() }
        if insetScrollable.map({ $0 === root || isInside($0, root) }) == true { insetScrollable = nil }
    }
    private func isInside(_ node: UINode, _ root: UINode) -> Bool {
        var n: UINode? = node
        while let cur = n { if cur === root { return true }; n = cur.parent }
        return false
    }

    // MARK: - the safe area

    /// The window's insets changed (the host pushed them as the globals, re-resolving every live
    /// root): the shrunk root's collapsed bottom is restated on top.
    func safeInsetsChanged(_ insets: UIEdgeInsets) {
        realSafeInsets = insets
        if let root = shrunkRoot { overrideRootSafeBottom(root, 0) }
    }

    /// Re-resolve ONE root's dynamic styles with `bottom` as its bottom safe inset, the globals
    /// untouched: 0 collapses it for the root the keyboard shrinks (the keyboard stands in for the
    /// home indicator), the real value restores it.
    private func overrideRootSafeBottom(_ root: UINode, _ bottom: CGFloat) {
        guard !root.isRemoved else { return }   // nothing left to re-resolve, and the walk would run over freed memory
        CreatorUI.overrideRootSafeBottom(root.id, bottom: Float(bottom))
    }

    // MARK: - the shrink

    /// Pick the mode and the root, publish to the runtime, ask for a layout pass. Called on every
    /// keyboard change, focus change and policy change.
    func applyKeyboardLayout() {
        guard host.bounds.width > 0, host.bounds.height > 0 else { return }
        if let r = shrunkRoot, r.isRemoved { clearShrunkRoot() }

        // While focus hands off between fields (enterKey: "next") activeInput is briefly nil and no
        // notification fires — keep the current root shrunk rather than restore and re-shrink.
        let target: UINode? = effectiveInset > 0 ? (focusedRoot() ?? shrunkRoot) : nil
        if effectiveInset > 0, activeInput == nil, insetScrollable != nil { return }

        if let root = target, let scroll = insetModeScrollable(in: root) {
            if let prev = shrunkRoot {   // mode switch: the full layout first
                overrideRootSafeBottom(prev, realSafeInsets.bottom)
                clearShrunkRoot()
                requestLayout(prev)
            }
            applyKeyboardContentInset(scroll)
            return
        }
        clearKeyboardContentInset()

        let overlap = target.map(overlap(of:)) ?? 0
        let next = overlap > 0 ? target : nil
        let previous = shrunkRoot
        guard previous !== next || shrunkOverlap != overlap else {
            revealFocusedInput()
            return
        }
        shrunkRoot = next
        shrunkOverlap = next != nil ? overlap : 0
        Core.setShrunkRoot(next?.id ?? 0, overlap: Float(shrunkOverlap))
        if let previous, previous !== next {
            overrideRootSafeBottom(previous, realSafeInsets.bottom)
            requestLayout(previous)
        }
        if let next {
            overrideRootSafeBottom(next, 0)
            requestLayout(next)
        }
        pendingReveal = true
    }

    /// The runtime's frame pass lays every live root out with the shrink; a request makes it run.
    private func requestLayout(_ root: UINode) {
        FrameBatcher.request(root)
        host.widgetHost.layoutAll()   // a widget root's out-of-band box goes through rootLayoutHeight
    }

    /// The host's layout pass ran (the frames landed): the reveal that waited for it. The pass
    /// itself is wrapped in the keyboard's animation when one is pending (`takeAnimation`).
    func afterLayoutFrame() {
        guard pendingReveal else { return }
        pendingReveal = false
        revealFocusedInput()
    }
    func takeAnimation() -> (duration: TimeInterval, curve: UIView.AnimationOptions)? {
        defer { pendingAnimation = nil }
        return pendingAnimation
    }

    // MARK: - native inset mode

    /// The focused input's nearest vertical scrollable (a vlist keeps the core's window, it never
    /// takes the inset) IF that scrollable's bottom reaches the root's laid-out bottom — then
    /// nothing sits below it that a shrink would lift above the keyboard, and the inset is
    /// equivalent (the safe-bottom allowance covers the home indicator's gap).
    private func insetModeScrollable(in root: UINode) -> UINodeScrollable? {
        guard let input = activeInput else { return nil }
        var n = input.parent
        var found: UINodeScrollable?
        while let cur = n, cur !== root {
            if let s = cur as? UINodeScrollable, !(s is UINodeVList) { found = s; break }
            n = cur.parent
        }
        guard let scroll = found, scroll.isVertical, scroll.lastLayout != nil else { return nil }
        let region = region(of: root)
        // The root's CURRENT layout height (shrunk or full), matching the frames measured here.
        let current = region.bounds.height - (shrunkRoot === root ? shrunkOverlap : 0)
        let bottomInRegion = scroll.view.convert(scroll.view.bounds, to: region).maxY
        return bottomInRegion >= current - realSafeInsets.bottom - 2 ? scroll : nil
    }

    private func applyKeyboardContentInset(_ scroll: UINodeScrollable) {
        if let prev = insetScrollable, prev !== scroll { prev.clearKeyboardInset() }
        insetScrollable = scroll
        // The scrollable's own overlap with the keyboard band (a page's body may end above the raw
        // inset).
        let bottomInHost = scroll.view.convert(scroll.view.bounds, to: host).maxY
        let keyboardTop = host.bounds.height - keyboardInset
        scroll.setKeyboardInset(max(0, min(bottomInHost - keyboardTop, keyboardInset)))
        revealFocusedInput()
    }

    private func clearKeyboardContentInset() {
        guard let scroll = insetScrollable else { return }
        insetScrollable = nil
        scroll.clearKeyboardInset()   // mid-bounce the view defers the teardown to the settle
    }

    /// Keep the focused field visible: its nearest scrollable scrolls so the field sits above the
    /// keyboard, with breathing room.
    private func revealFocusedInput() {
        guard let input = activeInput, !input.isRemoved else { return }
        var n = input.parent
        while let cur = n {
            if let s = cur as? UINodeScrollable, !(s is UINodeVList) { s.reveal(input.view); return }
            n = cur.parent
        }
    }

    // MARK: - dismissal

    /// A clean tap outside every control while the keyboard is up (the host's tap recognizer asks
    /// on the touch): only when the focused input allows it.
    func shouldDismiss(onTouchIn view: UIView?) -> Bool {
        keyboardInset > 0 && activeInputDismiss && !KeyboardDismissal.insideControl(view, root: host)
    }

    /// Close the keyboard and drop focus: the first responder inside the root resigns, its blur
    /// listeners fire.
    func hideKeyboard() { host.endEditing(true) }

    /// The presented content changed (a screen, a destination, a pager page): a keyboard raised by
    /// the content being left behind must not survive into what replaces it — a pager keeps its
    /// pages attached, so the focused field would stay alive under the new page.
    func dismissKeyboardForNavigation() { host.endEditing(true) }
}
