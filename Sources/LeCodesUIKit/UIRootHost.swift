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
    /// Widgets attached to a page follow a page appearing / disappearing.
    func updateAttachedWidgets()
    /// The presented screen's root, nil while a scene / native view / video is the destination.
    var currentScreen: UINode? { get }
    /// A screen root's background color changed (a live re-theme): the root's backdrop and the
    /// status bar follow it while that screen is the presented one.
    func screenBackgroundChanged(_ screen: UINode)
    /// Whether the registerView instance `viewId` is the presented (fullscreen) destination right
    /// now: its node then leaves the instance view where it is (see UINodeNativeView.adopt).
    func isPromoted(viewId: Int) -> Bool
    /// The view controller a system sheet is presented from (a picker, a share sheet): the one the
    /// root is mounted in, nil while none is.
    var presentingViewController: UIViewController? { get }
}

/// The tap-outside keyboard dismissal's exception list (the host's gesture asks): a control keeps
/// the keyboard up — a send button must fire WITH it, a tap on another field just moves the
/// focus. Anything else under a clean tap dismisses.
public enum KeyboardDismissal {
    public static func isControl(_ view: UIView) -> Bool { view is UITextField || view is UITextView || view is ButtonView }
    /// Is `view` a control or inside one (up to `root`)?
    public static func insideControl(_ view: UIView?, root: UIView) -> Bool {
        var v = view
        while let cur = v, cur !== root {
            if isControl(cur) { return true }
            v = cur.superview
        }
        return false
    }
}
