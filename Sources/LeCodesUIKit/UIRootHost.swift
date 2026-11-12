// The view the renderer's views are mounted under (on iOS the host's LeCodesView). It is per window
// and outlives no window, so it is not part of RendererServices: a view finds it the way it always
// has — walking up its superviews, or through UINode.appRoot. The twin of renderers/android's
// UIRootHost.kt; it grows with the steps (inputs bring the focus hooks, the pull-to-refresh
// controller comes with the scrollables).
import UIKit

public protocol UIRootHost: AnyObject {
    /// The keyboard's overlap with the window's bottom edge, logical px: 0 with no keyboard.
    var keyboardInset: CGFloat { get }
    /// An input took focus: its keyboardShrink / keyboardDismiss policy now applies.
    func onInputFocused(_ input: UINodeInput)
    func onInputBlurred(_ input: UINodeInput)
    /// Hides the keyboard and drops focus (blur listeners fire).
    func hideKeyboard()
    /// A navigation (a pager page change): hides the keyboard if an input holds focus.
    func dismissKeyboardForNavigation()
    /// The presented screen's root, nil while a scene / native view is the destination.
    var currentScreen: UINode? { get }
    /// A screen root's background color changed (a live re-theme): the root's backdrop and the
    /// status bar follow it while that screen is the presented one.
    func screenBackgroundChanged(_ screen: UINode)
    /// The view controller a system sheet is presented from (a picker, a share sheet): the one the
    /// root is mounted in, nil while none is.
    var presentingViewController: UIViewController? { get }
}

/// The tap-outside keyboard dismissal's exception list (the host's gesture asks, per touch): a
/// control keeps the keyboard up — a send button must fire WITH it, a tap on another field just
/// moves the focus. A paragraph is a control where the finger lands on what it presses: an
/// interactive run (a link), or the paragraph when it listens — the press's own resolution
/// (TextView.takesPress, rule 5 of docs/plans/rich-text-plan.md); its plain words are not, they go
/// on to what holds them. Anything else under a clean tap dismisses.
public enum KeyboardDismissal {
    /// Does the touch land on a control or inside one (up to `root`)?
    public static func insideControl(_ touch: UITouch, root: UIView) -> Bool {
        insideControl(touch.view, at: root.rootPoint(of: touch), root: root)
    }
    /// `view`: the view the touch hit; `rootPoint`: the touch in the app root's space (the pointer's).
    static func insideControl(_ view: UIView?, at rootPoint: CGPoint, root: UIView) -> Bool {
        var v = view
        while let cur = v, cur !== root {
            if isControl(cur, at: rootPoint) { return true }
            v = cur.superview
        }
        return false
    }
    static func isControl(_ view: UIView, at rootPoint: CGPoint) -> Bool {
        if let text = view as? TextView { return text.takesPress(at: rootPoint) }
        return view is UITextField || view is UITextView || view is ButtonView
    }
}
