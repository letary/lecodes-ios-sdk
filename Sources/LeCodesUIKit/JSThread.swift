// An event the renderer must deliver OUTSIDE the UIKit transaction it learned it in (a gesture's
// settle, a scrim tap): posted to the JS thread — the main thread, where the runtime runs, so the
// default is the main queue. A check runner or a test that drives the runtime from its own thread
// replaces `post` with a queue it drains itself, between ticks: the events then reach JS on the
// runtime's thread, deterministically.
import Foundation

public enum JSThread {
    public static var post: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
}
