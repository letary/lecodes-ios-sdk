// The `scene2d` table (2d.d.ts) — the twin of hosts/android's Scene2dHost.kt: creator-2d's Metal
// setup on the process's device (init2D, instead of the engine's default GL c2dInit), scene.open()
// / close() bringing the presented Scene2DView up and down through the root view, and the 2D FRAME
// the engine's tick drives after the runtime's (frame): the presented scene into its view's surface
// (the runtime's 2D frame: the SDK hooks, the simulation, the draw), or — with none presented but
// `UIImage(scene2d)` nodes alive (a 3D game's minimap) — the simulation-only frame, then every image
// node's scene drawn into its own surface. `openSceneId` is retained so a re-created root view can
// rebuild the view: the slot only fires on the JS side's call.
import Foundation
import LeCodesCore
import LeCodesUIKit

final class Scene2dHost: HostScene2d {
    weak var engine: LeCodesEngine?
    private(set) var openSceneId: Int32?

    /// The scene is open but its view cannot take the frame yet (no size, no root view): the frame
    /// renders here so the simulation still steps and nothing is drawn into a missing swapchain.
    private lazy var fallback = Scene2DSurface()

    var init2D: (() -> Void)? {
        {
            guard let device = MetalDevice.shared else { print("[scene2d] no Metal device: the 2D engine stays down"); return }
            Core.scene2dInitMetal(device: device)
        }
    }
    var open2DScene: ((Int32) -> Void)? {
        { [weak self] sceneId in
            Core.scene2dEnsureInited()   // the lazy sg_setup (init2D) before the first frame draws
            self?.openSceneId = sceneId
            self?.engine?.rootView?.ensureScene2dView()
        }
    }
    var close2DScene: (() -> Void)? {
        { [weak self] in
            self?.openSceneId = nil
            self?.engine?.rootView?.scene2dClosed()
        }
    }

    /// The 2D half of the host's frame, after Core.runTick.
    func frame(nowMs: Int64) {
        if Core.scene2dOpen {
            if let view = engine?.rootView?.scene2dView, view.renderFrame(nowMs: nowMs) {
                // drawn into the presented view
            } else if fallback.resize(2, 2), let target = fallback.beginFrame() {
                Core.scene2dSetPresentTarget(target)
                Core.scene2dRenderFrame(nowMs: nowMs)
                fallback.present()
            }
        } else if !Scene2DImages.isEmpty {
            Core.scene2dRenderFrame(nowMs: nowMs)   // no scene presented: the simulation only
        }
        Scene2DImages.drawAll()
    }
}
