// The core's color word (0xRRGGBBAA, the same on every host) as a UIColor — the renderer's one
// RGBA edge, like renderers/android's rgbaToArgb.
import UIKit

extension UIColor {
    public convenience init(rgba: UInt32) {
        self.init(red: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
}
