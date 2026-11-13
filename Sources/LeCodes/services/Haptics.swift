// device.vibrate: the semantic style → the matching UIFeedbackGenerator, fired once on the main
// thread. A silent no-op on hardware without a Taptic Engine (iPad, older iPhones).
import UIKit

enum Haptics {
    static func vibrate(_ style: String) {
        DispatchQueue.main.async {
            switch style {
            case "light":     UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case "medium":    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "heavy":     UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "soft":      UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            case "rigid":     UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            case "success":   UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning":   UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error":     UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "selection": UISelectionFeedbackGenerator().selectionChanged()
            // Android's EFFECT_TICK, a short crisp tap: .rigid is the nearest generator.
            case "tick":      UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            // A dull, strong thump: the soft generator at its full intensity.
            case "thud":      UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 1.0)
            default:          UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }
}
