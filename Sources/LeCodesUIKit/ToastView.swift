// The toast (HostUI.showToast): a translucent pill near the bottom of the root view, faded in
// and out, above the keyboard band (the root host's inset; re-seated when the keyboard moves).
// Messages queue: overlapping toasts show one after another. Lifted from the old host, mounted
// on the app root instead of the window (an embedded viewer keeps its toasts inside itself).
import UIKit

public final class ToastView: UIView {
    private let label = UILabel()
    private var keyboardObserver: NSObjectProtocol?

    private static var queue: [(String, Int, UIView)] = []
    private static var showing: ToastView?

    /// Queue `text` over `host`; shown once the toast in flight (if any) has faded.
    public static func show(_ text: String, durationMs: Int, in host: UIView) {
        queue.append((text, durationMs, host))
        showNextIfNeeded()
    }

    private static func showNextIfNeeded() {
        guard showing == nil, let next = queue.first else { return }
        queue.removeFirst()
        let toast = ToastView()
        showing = toast
        toast.present(next.0, durationMs: next.1, in: next.2)
    }

    private init() {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.7)
        layer.cornerRadius = 12
        clipsToBounds = true
        isUserInteractionEnabled = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.numberOfLines = 0
        label.textAlignment = .center
        addSubview(label)
        keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] _ in
            // The host's inset is written by the same notification, in whichever order: seat on
            // the next turn, when both have seen it.
            DispatchQueue.main.async { self?.seat(animated: true) }
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    deinit { if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) } }

    public override func layoutSubviews() {
        super.layoutSubviews()
        label.place(bounds.insetBy(dx: 12, dy: 8))
    }

    private func present(_ text: String, durationMs: Int, in host: UIView) {
        label.text = text
        let maxWidth = max(host.bounds.width * 0.8, 40)
        let fit = label.sizeThatFits(CGSize(width: maxWidth - 24, height: .greatestFiniteMagnitude))
        bounds.size = CGSize(width: min(maxWidth, fit.width + 24), height: fit.height + 16)
        host.addSubview(self)
        seat(animated: false)
        let hold = TimeInterval(max(durationMs, 0)) / 1000
        let done = { [weak self] in
            self?.removeFromSuperview()
            if ToastView.showing === self { ToastView.showing = nil }
            ToastView.showNextIfNeeded()
        }
        guard Animations.enabled else {
            alpha = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: done)
            return
        }
        alpha = 0
        UIView.animate(withDuration: 0.3) { self.alpha = 1 } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: hold, options: .curveEaseInOut) { self.alpha = 0 } completion: { _ in done() }
        }
    }

    /// 60 pt above the host's bottom edge, lifted by the keyboard's overlap.
    private func seat(animated: Bool) {
        guard let host = superview else { return }
        let inset = (host as? UIRootHost)?.keyboardInset ?? 0
        let size = bounds.size
        let seat = CGRect(x: (host.bounds.width - size.width) / 2, y: host.bounds.height - size.height - 60 - inset, width: size.width, height: size.height)
        guard animated, Animations.enabled else { place(seat); return }
        UIView.animate(withDuration: 0.25) { self.place(seat) }
    }
}
