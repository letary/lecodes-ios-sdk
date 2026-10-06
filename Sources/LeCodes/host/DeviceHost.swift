// The `device` table (device.d.ts): the platform fields, precise touch, haptics, device.motion, the
// clipboard, share, the file picker and the camera permission — every "ask the OS" call that is
// not a network, a store or a player.
import Foundation
import UIKit
import AVFoundation
import LeCodesCore

final class DeviceHost: HostDevice {
    weak var engine: LeCodesEngine?
    private let motion = Motion()
    private let picker = FilePicker()

    // device.platform names the INPUT MODEL (apps branch on it), not the OS.
    var platform: String { "ios" }
    var language: String { engine?.language ?? "en" }
    /// Physical px per logical px — the main screen's scale (2–3 on retina).
    var pixelRatio: Double { Double(UIScreen.main.scale) }

    var setPreciseTouch: ((Bool) -> Void)? { { [weak self] on in self?.engine?.preciseTouch = on } }
    var vibrate: ((String) -> Void)? { { style in Haptics.vibrate(style) } }
    // device.statsOverlay — the host's own line of frame numbers (StatsOverlay.swift), the engine's state.
    var setStatsOverlay: ((Bool) -> Void)? { { [weak self] on in self?.engine?.statsOverlay.enabled = on } }
    var statsOverlay: (() -> Bool)? { { [weak self] in self?.engine?.statsOverlay.enabled ?? false } }
    var motionAvailable: (() -> Bool)? { { [weak self] in self?.motion.available ?? false } }
    var motionStart: ((Double) -> Bool)? { { [weak self] interval in self?.motion.start(interval: interval) ?? false } }
    var motionStop: (() -> Void)? { { [weak self] in self?.motion.stop() } }
    var motionSample: (() -> [Float]?)? { { [weak self] in self?.motion.sample() } }
    var clipboardWrite: ((String) -> Void)? { { text in UIPasteboard.general.string = text } }
    /// Native reads complete synchronously (the async shape exists for web's permission prompt).
    var clipboardRead: ((JSCallback, JSCallback) -> Void)? {
        { onComplete, onReject in
            if let text = UIPasteboard.general.string, !text.isEmpty { Core.resolve(onComplete, reject: onReject, [.string(text)]) }
            else { Core.reject(onComplete, reject: onReject, message: "Clipboard is empty") }
        }
    }
    var share: ((Int32, String?) -> Void)? {
        { [weak self] systemId, text in
            guard let data = Buffers.get(systemId) else { print("[device] share: stale buffer \(systemId)"); return }
            self?.picker.share(data, text)
        }
    }
    /// The picked files as `[systemId, name, size]` rows in ONE argument (an empty list = cancelled).
    var openFilePicker: ((JSCallback, JSCallback, Bool, String?) -> Void)? {
        { [weak self] onComplete, onReject, multiple, accept in
            let types = FilePicker.tokens(accept)
            guard let self else { Core.resolve(onComplete, reject: onReject, [.array([])]); return }
            self.picker.open(accept: types, multiple: multiple) { files in
                let rows: [LeValue] = files.map { .array([.int(Buffers.add($0.data)), .string($0.name), .int(Int32($0.data.count))]) }
                Core.resolve(onComplete, reject: onReject, [.array(rows)])
            }
        }
    }
    var requestCamera: ((JSCallback, JSCallback) -> Void)? {
        { onComplete, onReject in
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: Core.resolve(onComplete, reject: onReject)
            case .denied, .restricted: Core.reject(onComplete, reject: onReject, message: "Camera is not available")
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted { Core.resolve(onComplete, reject: onReject) }
                    else { Core.reject(onComplete, reject: onReject, message: "Camera is not available") }
                }
            @unknown default: Core.reject(onComplete, reject: onReject, message: "Camera is not available")
            }
        }
    }

    func dispose() { motion.stop() }
}
