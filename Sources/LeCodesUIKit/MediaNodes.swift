// The node whose content is a surface the HOST owns: the video node (an AVPlayerLayer over the
// AVPlayer behind the SDK's VideoPlayer — RendererServices.mediaPlayer). A node, never a
// destination (docs/tree.md, "A node or a destination"): a fullscreen video is a screen holding a
// video node, and every node made for one player shows it — each has its own layer over the same
// AVPlayer, so the box under a pushed fullscreen screen keeps its picture and playback never stops.
// (A registerView plugin's view is a destination only: the host presents it, no node holds it.)
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
