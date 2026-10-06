// An AR session behind HostGL.launchAR — the seam the AR package (LeCodesAR: ARKitController over
// ARKit) implements and the engine's registry (LeCodesEngine.registerARController) hands out by
// mode name (`createARController(mode)` in the SDK: "world", "markers"). The twin of hosts/android's
// ARController: the GL host creates one per scene that asked, starts it on launchAR, stops it on
// stopAR; the controller drives the engine itself (the camera texture, the projection, the camera
// pose, the anchors' matrices and tracking states) through Core's AR calls. Main thread only.
import Foundation

public protocol ARController: AnyObject {
    /// Set by the GL host right after the factory made the controller.
    var sceneId: UInt32 { get set }
    var cameraEntityId: UInt32 { get set }

    /// The scene's root anchor entity (`scene.root`): placed on the first detected plane.
    func createRootAnchor(_ entityId: UInt32)
    /// An image anchor: track the encoded image (`physicalWidth` metres) on the entity.
    func createAnchor(_ entityId: UInt32, _ data: Data, _ physicalWidth: Float)

    /// Start the session; exactly one of the two closures fires (the first frame, or a failure).
    func start(_ onStart: @escaping () -> Void, _ onStartFailed: @escaping (_ message: String) -> Void)
    func stop()
}
