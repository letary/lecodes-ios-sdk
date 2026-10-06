// `device.statsOverlay` (HostDevice.setStatsOverlay): one line over everything —
//
//     72 fps  67% even  cpu 1.1
//
// the 3D frames per second, the share of them that stayed on screen the most common number of
// display periods (a mix of one- and two-period frames is judder whatever the average says — only
// where the platform reports when a frame was shown; Metal does not, so iOS shows no `even`) and the
// main thread's milliseconds per frame — the whole tick: JS, layout, the submit. A low fps under a
// small cpu is the GPU's. Without a 3D scene only the last is there.
//
// Nothing of it is in the app's frame: the engine counts its own frames and reads the history
// Filament keeps anyway (Core.framePacing), the tick is timed with two clock reads, and the line is
// a plain view in the WINDOW — outside LeCodesView, its layout and the UI tree — relaid when the
// text changes, once a second. The host's state, not a world's: it stays through a project swap.
// The twin of hosts/android's StatsOverlay.kt.
import LeCodesCore
import LeCodesUIKit
import UIKit

final class StatsOverlay {
    private weak var engine: LeCodesEngine?
    init(engine: LeCodesEngine) { self.engine = engine }

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            Core.setFramePacing(enabled)
            windowStart = 0
            if enabled { mount() } else { unmount() }
        }
    }

    private(set) var view: StatsView?
    private var windowStart: TimeInterval = 0
    private var tickSeconds: TimeInterval = 0
    private var ticks = 0

    /// The root view is in a window: the line goes into it (LeCodesView.didMoveToWindow).
    func attach() { if enabled { mount() } }
    /// The root view left its window, or the engine is torn down.
    func detach() { unmount() }

    /// One tick ran from `start` to `end` (LeCodesEngine.tick, only while enabled; the uptime clock, seconds).
    func frame(start: TimeInterval, end: TimeInterval) {
        if windowStart == 0 { windowStart = start; tickSeconds = 0; ticks = 0 }
        tickSeconds += end - start
        ticks += 1
        let window = end - windowStart
        guard window >= 1 else { return }
        view?.show(StatsOverlay.line(seconds: window, cpuMs: tickSeconds * 1000 / Double(ticks), pacing: Core.framePacing()))
        windowStart = end
        tickSeconds = 0
        ticks = 0
    }

    /// The line of a stretch of `seconds`: `pacing` = Core.framePacing's [frames, timed, even,
    /// periods, periodMs, gpuFrameMs] over it, nil without a 3D engine.
    static func line(seconds: Double, cpuMs: Double, pacing: [Float]?) -> String {
        let cpu = String(format: "cpu %.1f", cpuMs)
        guard let p = pacing, p.count >= 4, p[0] >= 1 else { return cpu }
        var s = "\(Int((Double(p[0]) / seconds).rounded())) fps"
        if p[1] >= 1 { s += "  \(Int((100 * p[2] / p[1]).rounded()))% even" }
        // No GPU time, as on Android: on a tile-based GPU Filament's timer query reads the frame
        // INTERVAL, not the work — it says nothing the fps has not.
        return s + "  " + cpu
    }

    private func mount() {
        guard let window = engine?.rootView?.window else { return }
        unmount()
        let v = StatsView()
        v.place(window.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(v)
        view = v
    }

    private func unmount() {
        view?.removeFromSuperview()
        view = nil
    }
}

/// The line over the window: a layer no touch meets, the plate under the status bar and the
/// notch, sized to the text (a new text is one relayout of two views, nothing of the tree's).
final class StatsView: UIView {
    private let plate = UIView()
    private let label = UILabel()
    private let padH: CGFloat = 8
    private let padV: CGFloat = 3
    var line: String { label.text ?? "" }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        plate.backgroundColor = UIColor(white: 0, alpha: 0.7)
        plate.layer.cornerRadius = 6
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .white
        label.textAlignment = .center
        label.text = "…"
        addSubview(plate)
        plate.addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func show(_ value: String) {
        guard label.text != value else { return }
        label.text = value
        setNeedsLayout()
    }

    override func safeAreaInsetsDidChange() { setNeedsLayout() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let text = ceil(label.intrinsicContentSize.width)
        let width = text + 2 * padH
        let height = ceil(label.font.lineHeight) + 2 * padV
        plate.place(CGRect(x: ((bounds.width - width) / 2).rounded(), y: safeAreaInsets.top + 2, width: width, height: height))
        label.place(plate.bounds.insetBy(dx: padH, dy: padV))
    }
}
