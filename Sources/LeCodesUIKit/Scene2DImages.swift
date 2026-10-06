// A live creator-2d scene on screen — the Apple flavour of the 2D engine's output (the twin of
// renderers/android's Scene2DImageView + Scene2DImages, and of the old host's Scene2DImages.swift):
// the engine draws through an offscreen TARGET (Core.scene2dTargetCreateMetal / scene2dDrawSceneTarget)
// whose color texture is an IOSurface-backed MTLTexture this side owns, and a CALayer shows that
// IOSurface as its contents — zero copies, and the node's own corner radius / opacity / clipping apply
// to the sublayer as to any content. Two surfaces alternate (ping-pong) so the frame Core Animation
// is compositing is never the one sokol is writing.
//
// Two consumers: `UIImage(scene2d)` — a node's box is the render size, the scene's own camera projects
// into it, drawn every frame by Scene2DImages.drawAll from the host's frame after the 2D simulation
// stepped (the host's `pkg2dRenderFrame`); and the PRESENTED 2D scene, whose fullscreen view (the
// host's) renders the frame into its surface as the engine's present target. Main thread only.
import IOSurface
import LeCodesCore
import Metal
import QuartzCore
import UIKit

/// One render surface: a CALayer showing whichever of two IOSurfaces the engine last drew into.
/// Sized in PHYSICAL px; a resize drops both buffers.
public final class Scene2DSurface {
    /// The content layer — the owner adds it under its own layer and frames it.
    public let layer = CALayer()

    private struct Buffer {
        let surface: IOSurface
        let texture: MTLTexture      // keeps the IOSurface alive for the engine's target
        let target: Int32            // creator-2d target id
    }
    private var buffers: [Buffer] = []
    private var next = 0             // the buffer the next draw writes
    private var shown: Buffer?       // the buffer the layer displays
    public private(set) var pixelWidth = 0
    public private(set) var pixelHeight = 0

    public init() {
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.isOpaque = false
        // A standalone CALayer animates every property change implicitly (0.25 s) — at one contents
        // swap per frame that would be a permanent crossfade. Turn the actions off once instead of
        // opening a transaction per frame.
        let none = NSNull()
        layer.actions = ["contents": none, "bounds": none, "position": none, "frame": none,
                         "contentsScale": none, "hidden": none]
    }

    deinit { release() }

    /// (Re)create the buffer pair at a pixel size. True when the engine accepted both targets (also
    /// when the size is unchanged and they exist). False without creator-2d / a Metal device.
    @discardableResult
    public func resize(_ width: Int, _ height: Int) -> Bool {
        if width == pixelWidth, height == pixelHeight, buffers.count == 2 { return true }
        release()
        guard width > 0, height > 0, let device = MetalDevice.shared else { return false }
        // sg_setup runs lazily on the first GPU-touching call (HostScene2d.init2D: Metal on the
        // device) — a target is one, and an image node's scene may be the first thing to draw.
        Core.scene2dEnsureInited()
        for _ in 0..<2 {
            guard let b = Self.makeBuffer(device, width, height) else { release(); return false }
            buffers.append(b)
        }
        pixelWidth = width
        pixelHeight = height
        next = 0
        return true
    }

    /// The target id the next frame draws into (nil before a successful resize); `present()` shows it.
    public func beginFrame() -> Int32? {
        guard buffers.count == 2 else { return nil }
        return buffers[next].target
    }
    /// Show the buffer `beginFrame` handed out: assigning the OTHER IOSurface each frame is what makes
    /// Core Animation pick the new picture up (the same object would not re-commit).
    public func present() {
        guard buffers.count == 2 else { return }
        let b = buffers[next]
        next = (next + 1) % buffers.count
        layer.contents = b.surface
        shown = b
    }

    /// Draw `sceneId` (its own camera, no simulation) into the next buffer and show it. `density` =
    /// physical px per logical point, so camera zoom keeps its meaning in the box.
    public func draw(sceneId: Int32, density: Float) {
        guard let target = beginFrame() else { return }
        Core.scene2dDrawSceneTarget(sceneId: sceneId, targetId: target, density: density)
        present()
    }

    /// The pixels of the buffer on screen (RGBA8 rows of `bytesPerRow`), nil before the first
    /// present. GPU completion is not awaited: a test polls until the picture settles.
    public func readback() -> (data: Data, width: Int, height: Int, bytesPerRow: Int)? {
        guard let b = shown else { return nil }
        let s = b.surface
        s.lock(options: [.readOnly], seed: nil)
        defer { s.unlock(options: [.readOnly], seed: nil) }
        return (Data(bytes: s.baseAddress, count: s.allocationSize), s.width, s.height, s.bytesPerRow)
    }
    /// One pixel of the shown buffer as (r, g, b, a), nil when off the surface / before a present.
    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let r = readback(), x >= 0, y >= 0, x < r.width, y < r.height else { return nil }
        let i = y * r.bytesPerRow + x * 4
        return (r.data[i], r.data[i + 1], r.data[i + 2], r.data[i + 3])
    }

    private func release() {
        for b in buffers { Core.scene2dTargetDestroy(b.target) }
        buffers.removeAll()
        shown = nil
        pixelWidth = 0
        pixelHeight = 0
    }

    // An RGBA8 IOSurface ('RGBA', the sprite pipeline's color format — a Metal pass can only target
    // the format its pipeline declares), wrapped as a render-target texture the engine adopts.
    private static func makeBuffer(_ device: MTLDevice, _ width: Int, _ height: Int) -> Buffer? {
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let props: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: bytesPerRow,
            .allocSize: IOSurfaceAlignProperty(kIOSurfaceAllocSize, bytesPerRow * height),
            .pixelFormat: UInt32(0x52474241),   // 'RGBA' (kCVPixelFormatType_32RGBA)
        ]
        guard let surface = IOSurface(properties: props) else { warnOnce("no IOSurface for \(width)×\(height)"); return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else { warnOnce("no Metal texture over the IOSurface"); return nil }
        texture.label = "creator2d-target"
        let target = Core.scene2dTargetCreateMetal(width: width, height: height, texture: texture)
        guard target != 0 else { warnOnce("the engine refused the target (no creator-2d, or its Metal setup did not run)"); return nil }
        return Buffer(surface: surface, texture: texture, target: target)
    }

    /// A surface that cannot be made says so once per process (not once per frame).
    private static var warned = false
    private static func warnOnce(_ what: String) {
        guard !warned else { return }
        warned = true
        print("[scene2d] \(what): the scene stays blank")
    }
}

/// The image nodes showing a live 2D scene (`scene2d:<id>` sources) and the per-frame draw over
/// them. The host's frame calls `drawAll` after the 2D engine stepped (with a presented 2D scene:
/// its frame; with none: the simulation-only frame the host runs while `isEmpty` is false).
public enum Scene2DImages {
    private struct Entry {
        weak var node: UINodeImage?
        var sceneId: Int32
        let surface: Scene2DSurface
    }
    private static var entries: [ObjectIdentifier: Entry] = [:]

    public static var isEmpty: Bool { entries.isEmpty }
    public static var count: Int { entries.count }

    /// Show `sceneId` in the node's box from the next frame on. Re-attaching with another scene keeps
    /// the surfaces (a scene → scene src swap, same box).
    static func attach(_ node: UINodeImage, sceneId: Int32) {
        let key = ObjectIdentifier(node)
        if var e = entries[key], e.node === node {
            e.sceneId = sceneId
            entries[key] = e
            return
        }
        // A stale entry under this address (its node was freed, the address reused) is replaced.
        entries[key]?.surface.layer.removeFromSuperlayer()
        let surface = Scene2DSurface()
        node.view.layer.addSublayer(surface.layer)
        entries[key] = Entry(node: node, sceneId: sceneId, surface: surface)
    }

    /// The node no longer shows a scene (its src changed, or it is going away).
    static func detach(_ node: UINodeImage) {
        guard let e = entries.removeValue(forKey: ObjectIdentifier(node)) else { return }
        e.surface.layer.removeFromSuperlayer()
    }

    /// The surface of a node showing a scene (a test reads its pixels back).
    public static func surface(of node: UINodeImage) -> Scene2DSurface? {
        guard let e = entries[ObjectIdentifier(node)], e.node === node else { return nil }
        return e.surface
    }

    /// Draw every attached node's scene into its surface, sized to the node's CURRENT box. Once per
    /// host frame after the engine stepped, so followers / cameras drawn here are this frame's.
    public static func drawAll() {
        guard !entries.isEmpty else { return }
        var dead: [ObjectIdentifier] = []
        for (key, e) in entries {
            guard let node = e.node else { dead.append(key); continue }
            let view = node.view
            guard !node.isRemoved, !view.isHidden, Self.isOnScreen(view) else { continue }
            let bounds = view.bounds
            guard bounds.width >= 1, bounds.height >= 1 else { continue }   // not laid out yet
            let scale = Self.displayScale(view)
            let pw = Int((bounds.width * scale).rounded()), ph = Int((bounds.height * scale).rounded())
            let layer = e.surface.layer
            if layer.frame != bounds { layer.frame = bounds }
            if layer.contentsScale != scale { layer.contentsScale = scale }
            guard e.surface.resize(pw, ph) else { continue }
            e.surface.draw(sceneId: e.sceneId, density: Float(scale))
        }
        for key in dead { entries.removeValue(forKey: key) }
    }

    /// In a window, or under the app root (a test's root has no window).
    private static func isOnScreen(_ view: UIView) -> Bool {
        if view.window != nil { return true }
        if let root = UINode.appRoot { return view.isDescendant(of: root) }
        return false
    }
    /// Physical px per logical point of the node's screen — the density the engine projects the
    /// scene's camera with (the scene views derive the same ratio from their drawable).
    static func displayScale(_ view: UIView) -> CGFloat {
        if let s = view.window?.screen.scale, s > 0 { return s }
        let t = view.traitCollection.displayScale
        return t > 0 ? t : UIScreen.main.scale
    }
}
