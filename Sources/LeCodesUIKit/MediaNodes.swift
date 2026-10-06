// The two nodes whose content is a surface the HOST owns: the video node (an AVPlayerLayer over
// the AVPlayer behind the SDK's VideoPlayer — RendererServices.mediaPlayer) and the embedded
// native view (a registerView plugin's live view — RendererServices.nativeView). Both are also
// fullscreen destinations (TREE_DEST_VIDEO / TREE_DEST_NATIVE, presented by the host's root
// view): a video promotes by a SECOND player layer over the same player (playback never
// stops, the old host's model), a native view promotes by REPARENTING its one instance view —
// state intact — and the node adopts it back when the destination closes (`readopt`).
import AVFoundation
import LeCodesCore
import UIKit

/// A video surface ("video"): the player by id (`playerId` on the int channel), objectFit as the
/// layer's gravity, the measure from the item's presentation size once the first frame is
/// decoded (a layout pass re-measures it then).
public final class UINodeVideo: UINode {
    public private(set) var player: AVPlayer?
    private var gravity: AVLayerVideoGravity = .resizeAspect
    private var videoView: VideoView { view as! VideoView }

    override func createView() -> UIView { VideoView(node: self, player: player, gravity: gravity) }
    public override var hasMeasure: Bool { true }

    public override func setPropertyInt(_ prop: String, _ value: Int32) {
        guard prop == "playerId" else { return }
        // An unknown id (a removed player) is ignored, never a crash; the measure guards on nil.
        player = rendererServices?.mediaPlayer(id: Int(value))
        videoView.bind(player, gravity: gravity)
        FrameBatcher.request(self, measure: true)
    }

    public override func applyPaint(_ r: PaintRecord) {
        super.applyPaint(r)
        guard r.dirty(CuiPaint.Bit.objectFit) else { return }
        switch CuiPaint.ObjectFit(rawValue: r.word(CuiPaint.Word.objectFit)) ?? .contain {
        case .cover: gravity = .resizeAspectFill
        case .contain: gravity = .resizeAspect
        case .fill: gravity = .resize
        }
        videoView.setGravity(gravity)
    }

    /// The frame's size, fit within the constraints without upscaling (the image node's rule);
    /// zero until the item's presentation size is known — a decode re-measures.
    override func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        guard let size = player?.currentItem?.presentationSize, size.width > 0, size.height > 0 else { return .zero }
        let wN = widthMode == 0 || width.isNaN ? CGFloat.greatestFiniteMagnitude : CGFloat(width)
        let hN = heightMode == 0 || height.isNaN ? CGFloat.greatestFiniteMagnitude : CGFloat(height)
        var k = min(wN / size.width, hN / size.height)
        if widthMode != 1, heightMode != 1 { k = min(k, 1) }
        return CGSize(width: size.width * k, height: size.height * k)
    }

    /// A layer over the same player for the fullscreen destination (the host's video surface).
    public func makePlayerLayer() -> AVPlayerLayer {
        let l = AVPlayerLayer(player: player)
        l.videoGravity = .resizeAspect
        return l
    }
}

final class VideoView: NodeView {
    private var playerLayer: AVPlayerLayer?
    private var readiness: NSKeyValueObservation?

    init(node: UINodeVideo, player: AVPlayer?, gravity: AVLayerVideoGravity) {
        super.init(node: node)
        clipsToBounds = true
        bind(player, gravity: gravity)
    }

    func bind(_ player: AVPlayer?, gravity: AVLayerVideoGravity) {
        readiness = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        guard let player else { return }
        let newLayer = AVPlayerLayer(player: player)
        newLayer.videoGravity = gravity
        newLayer.frame = bounds
        layer.addSublayer(newLayer)
        playerLayer = newLayer
        // The first decoded frame: the intrinsic size is known now, the node re-measures. KVO may
        // arrive off the main thread.
        readiness = newLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, let node = self.node, !node.isRemoved else { return }
                FrameBatcher.request(node, measure: true)
            }
        }
    }
    func setGravity(_ gravity: AVLayerVideoGravity) { playerLayer?.videoGravity = gravity }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }
}

/// An embedded registerView view ("native"): the name, the params as JSON and the stable instance
/// id arrive on the content channels before the view is built; the container adopts the host's
/// live instance view (created on first sight, reused across mounts — that reuse IS the
/// promotion semantics).
public final class UINodeNativeView: UINode {
    public private(set) var viewName: String?
    public private(set) var viewParams = "{}"
    public private(set) var viewId = 0
    /// The instance view this node adopted (the host's registry owns the instance).
    public private(set) weak var instanceView: UIView?

    override func createView() -> UIView {
        let container = NativeContainerView(node: self)
        container.clipsToBounds = true
        adopt(into: container)
        return container
    }

    public override func setProperty(_ prop: String, _ value: String?) {
        super.setProperty(prop, value)
        switch prop {
        case "viewName": viewName = value
        case "viewParams": viewParams = value ?? "{}"
        default: break
        }
    }
    public override func setPropertyInt(_ prop: String, _ value: Int32) {
        if prop == "viewId" { viewId = Int(value) }
    }

    private func adopt(into container: UIView) {
        guard let v = rendererServices?.nativeView(viewId: viewId, name: viewName, paramsJson: viewParams) else { return }
        instanceView = v
        // The same element is the destination AND this node (`QRScanner().open()`): when the
        // destination opened before this view was built — the paint pass builds views lazily — the
        // instance is on the root right now; taking it into this (unmounted) box would leave the
        // fullscreen destination empty while the camera runs. readopt() brings it back when it closes.
        if (UINode.appRoot as? UIRootHost)?.isPromoted(viewId: viewId) == true { return }
        v.removeFromSuperview()   // promotion / a re-mount: the instance may still sit in its previous host
        v.place(container.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(v)
    }

    /// The fullscreen destination that took the instance view closed: put it back in the box.
    public func readopt() {
        guard !isRemoved, let v = instanceView, v.superview !== view else { return }
        v.removeFromSuperview()
        v.place(view.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(v)
    }

    /// The node embedding the instance `viewId`, if one is live (the host asks on promotion).
    public static func embedding(viewId: Int) -> UINodeNativeView? {
        Nodes.all.first { ($0 as? UINodeNativeView)?.viewId == viewId && !$0.isRemoved } as? UINodeNativeView
    }
}

final class NativeContainerView: NodeView {}
