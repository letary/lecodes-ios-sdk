// The engine-only host: a HostUI that keeps no views — the runtime lays out and paints its tree of
// truth as always (the desktop's hidden-window and the windowless server run the same way), nothing
// is drawn, events never arrive. What the tests and the checks runner (check-sim.sh) boot; a
// renderer (renderers/uikit) replaces it in an app.
import Foundation
import LeCodesCore

public final class HeadlessUI: HostUI {
    public init() {}

    /// The node types by id, for a test that wants to see the tree exists.
    public private(set) var nodes: [Int: String] = [:]

    public func nodeFactory(id: Int, type: String, parent: Int, index: Int32) { nodes[id] = type }
    public func setPropertyString(id: Int, prop: String, value: String?) {}
    public func setPropertyInt(id: Int, prop: String, value: Int32) {}
    public func setFlags(id: Int, mask: UInt32) {}
    public func insertNode(parent: Int, child: Int, index: UInt16) {}
    public func removeNode(parent: Int, child: Int) {}
    public func releaseNode(id: Int) { nodes[id] = nil }
    public func openView(kind: UInt8, node: Int, id: Int32, viewName: String, paramsJson: String, above: Bool) {}
    public func dropView(kind: UInt8, node: Int, id: Int32) {}
    public func closeView() {}
    public func widgetOpen(node: Int, ownerKind: UInt8, ownerId: Int32, ownerNode: Int) {}
    public func widgetClose(node: Int) {}
    /// A font is "registered" at once: nothing measures with it here.
    public func registerFont(url: String, fontFamily: String, weight: Int32, style: Int32, onComplete: JSCallback, onReject: JSCallback) {
        Core.resolve(onComplete, reject: onReject)
    }
    public func showToast(message: String, duration: Int32) {}
    public func getButtonPressed(node: Int) -> Bool { false }
    public func getTextValue(node: Int) -> String { "" }
    public func vlistScroll(node: Int, scrollY: Float, animated: Bool) {}
}

/// The engine-only host's 3D table: Filament on its NOOP backend (LeCodesEngine sets it before the
/// app creates its engine), a headless swap chain as soon as the engine exists so it has its frame
/// lifecycle and the camera its projection — the two things a NOOP render target still owes the
/// simulation (the windowless server's rule; the frame phases and the physics step run inside the
/// engine's frame, and the runtime only drives a frame once a viewport is set). Textures are
/// refused: nothing decodes here.
public final class HeadlessGL: HostGL {
    public var width: UInt32
    public var height: UInt32
    /// The engine this table serves (LeCodesEngine sets it): a root view's scene view — the
    /// presentation is real even on the NOOP backend — hears the scene's close through it.
    weak var engine: LeCodesEngine?
    public init(width: UInt32 = 960, height: UInt32 = 600) {
        self.width = width
        self.height = height
    }
    public var engineCreated: (() -> Void)? {
        { [weak self] in
            guard let self else { return }
            Core.createSwapChainHeadless(width: self.width, height: self.height)
            Core.setViewport(width: self.width, height: self.height)
            print("[headless] engine created (NOOP backend, \(self.width)x\(self.height) viewport)")
        }
    }
    /// The scene closed for good: the root view drops its scene view (GLHost's twin).
    public var closeScene: (() -> Void)? {
        { [weak self] in self?.engine?.rootView?.sceneClosed() }
    }
    public func createTexture(systemId: Int32, flags: UInt32, onComplete: JSCallback, onReject: JSCallback) {
        Core.reject(onComplete, reject: onReject, message: "the engine-only host decodes no textures")
    }
}
