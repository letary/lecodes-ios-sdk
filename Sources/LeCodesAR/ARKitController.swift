// The ARKit session behind HostGL.launchAR — the twin of hosts/android/lecodes-ar's ARCoreController,
// the old host's ARKitController over the runtime's AR calls (Core, hosts-unification phase 6). An
// app that wants AR links this product and registers the kinds:
//   engine.registerARController("world") { ARKitController(.world) }
//   engine.registerARController("markers") { ARKitController(.markers) }
// (and carries NSCameraUsageDescription). The camera image streams into an external texture the
// camera plane's material samples (camera.filamat from the SDK's assets), the intrinsics go into the
// scene's projection every frame, the camera entity follows the device pose (rotated for the
// interface orientation), image anchors follow their ARImageAnchor and report tracking, the root
// anchor lands on the first horizontal plane.
import ARKit
import Foundation
import LeCodes
import LeCodesCore
import UIKit
import simd

public enum ARMode: UInt8 {
    case world = 0
    case markers = 1
}

public final class ARKitController: NSObject, ARSessionDelegate, ARController {
    public let mode: ARMode
    public var sceneId: UInt32 = 0
    public var cameraEntityId: UInt32 = 0

    private let materialInstanceId: UInt32
    private let texture: UInt32
    private var trackingImages = Set<ARReferenceImage>()
    private var rootAnchor: UInt32?
    private var session: ARSession?
    private var onStart: (() -> Void)?
    private var onStartFailed: ((String) -> Void)?
    private var tracked = Set<UInt32>()

    /// After the app's createEngine (the material and the texture are the engine's).
    public init(_ mode: ARMode) {
        self.mode = mode
        let material = Core.builtinMaterial("camera")
        if material == nil { print("[ar] no camera material: the camera image will not be drawn") }
        materialInstanceId = material ?? 0
        texture = Core.createExternalTexture()
        if material != nil { Core.setUniformTexture(materialInstanceId, "baseColorMap", texture: texture) }
        super.init()
    }
    public override convenience init() { self.init(.world) }

    // MARK: - ARController

    public func createRootAnchor(_ entityId: UInt32) { rootAnchor = entityId }

    public func createAnchor(_ entityId: UInt32, _ data: Data, _ physicalWidth: Float) {
        guard let image = UIImage(data: data)?.cgImage else { print("[ar] createAnchor: the marker image did not decode"); return }
        let marker = ARReferenceImage(image, orientation: .up, physicalWidth: CGFloat(physicalWidth))
        marker.name = String(entityId)
        trackingImages.insert(marker)
    }

    public func start(_ onStart: @escaping () -> Void, _ onStartFailed: @escaping (String) -> Void) {
        guard ARWorldTrackingConfiguration.isSupported else { onStartFailed("AR is not supported on this device"); return }
        Core.createARPlane(sceneId: sceneId, materialInstanceId: materialInstanceId)
        let configuration: ARConfiguration
        if mode == .markers {
            let c = ARImageTrackingConfiguration()
            c.trackingImages = trackingImages
            configuration = c
        } else {
            let c = ARWorldTrackingConfiguration()
            c.planeDetection = .horizontal
            c.detectionImages = trackingImages
            c.automaticImageScaleEstimationEnabled = true
            c.environmentTexturing = .none
            configuration = c
        }
        let session = ARSession()
        session.delegate = self
        session.delegateQueue = .main   // the engine is main-thread only
        self.session = session
        self.onStart = onStart
        self.onStartFailed = onStartFailed
        session.run(configuration)
    }

    public func stop() {
        session?.pause()
        session = nil
        tracked.removeAll()
        onStart = nil
        onStartFailed = nil
    }

    // MARK: - ARSessionDelegate

    public func session(_ session: ARSession, didFailWithError error: Error) {
        onStartFailed?(error.localizedDescription)
        onStartFailed = nil
        onStart = nil
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Core.updateTexture(texture, pixelBuffer: frame.capturedImage)
        if let onStart {
            self.onStart = nil
            onStartFailed = nil
            onStart()
        }
        let angle = Self.displayAngle
        let intrinsics = frame.camera.intrinsics
        Core.updateProjectionMatrixAR(sceneId: sceneId, fx: intrinsics[0][0], fy: intrinsics[1][1],
                                      cameraWidth: Float(frame.camera.imageResolution.width),
                                      cameraHeight: Float(frame.camera.imageResolution.height), displayAngle: angle)
        // The device pose is landscape-right native: rotate about Z for the interface orientation.
        let rotation = simd_float4x4(simd_quatf(angle: Float(angle) * .pi / 180, axis: simd_float3(0, 0, 1)))
        Core.setMatrix(entityId: cameraEntityId, frame.camera.transform * rotation)

        for anchor in frame.anchors {
            if let imageAnchor = anchor as? ARImageAnchor {
                guard let name = imageAnchor.name, let entityId = UInt32(name) else { continue }
                if imageAnchor.isTracked {
                    var m = imageAnchor.transform
                    let k = Float(imageAnchor.referenceImage.physicalSize.width * imageAnchor.estimatedScaleFactor)
                    m.columns.0 *= k
                    m.columns.1 *= k
                    m.columns.2 *= k
                    Core.setMatrix(entityId: entityId, m)
                }
                if imageAnchor.isTracked != tracked.contains(entityId) {
                    if imageAnchor.isTracked { tracked.insert(entityId) } else { tracked.remove(entityId) }
                    Core.updateTrackingState(entityId: entityId, tracking: imageAnchor.isTracked)
                }
            } else if let plane = anchor as? ARPlaneAnchor, let root = rootAnchor, !tracked.contains(root) {
                tracked.insert(root)
                Core.setMatrix(entityId: root, plane.transform)
                Core.updateTrackingState(entityId: root, tracking: true)
            }
        }
    }

    /// The camera image is landscape-right native; the angle the projection and the pose rotate by.
    private static var displayAngle: Int32 {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }.first ?? .portrait
        switch orientation {
        case .portrait: return 90
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        case .portraitUpsideDown: return -90
        default: return 0
        }
    }
}
