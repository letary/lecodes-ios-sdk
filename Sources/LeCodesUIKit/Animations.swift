// The renderer's one switch for everything it animates on the platform's own clock: a tween track
// it plays on Core Animation (LayerTween), the scroll to a selected tab, a sheet's settle, a toast,
// the keyboard's pass. Off = each lands at its end at once: a check runner's fixed clock runs app
// frames, not wall time, so whatever waits for the wall clock would never be seen landing — and a
// track is then played by the runtime, one write per frame.
public enum Animations {
    public static var enabled = true
}
