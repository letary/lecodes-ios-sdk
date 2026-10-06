// The registered fonts (HostUI.registerFont) and the face a text node resolves — the old host's
// FontManager, lifted. Key = family (lowercased) + weight (+ style when italic). A registered face
// is a CGFont through CTFontManagerRegisterGraphicsFont (an "already registered" error is a
// success); the lookup resolves through its PostScript name. Without a registered face the generic
// CSS families map to the system designs (monospace, serif, sans-serif) and anything else to the
// system font, italic synthesized through the descriptor traits. Fonts are swap-not-await: text
// renders in the fallback at once and every text node re-resolves when a face lands
// (`TextNodes.fontRegistered`). No Dynamic Type: sizes are raw points, like every other host.
import CoreText
import UIKit

public enum FontManager {
    private static var fonts: [String: CGFont] = [:]
    private static let lock = NSLock()

    private static func key(_ family: String, _ weight: Int, _ style: Int) -> String {
        style != 0 ? "\(family.lowercased())-\(weight)-\(style)" : "\(family.lowercased())-\(weight)"
    }

    /// Register a face from its bytes; false when the data is not a font. Any thread.
    @discardableResult
    public static func register(data: Data, family: String, weight: Int, style: Int) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else { return false }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterGraphicsFont(font, &error) {
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
            if code != CTFontManagerError.alreadyRegistered.rawValue { return false }
        }
        lock.lock()
        fonts[key(family, weight, style)] = font
        lock.unlock()
        // Every text node already on screen resolved a fallback and cached a measure against it —
        // both stale now. Views, so the main thread.
        if Thread.isMainThread { TextNodes.fontRegistered() } else { DispatchQueue.main.async { TextNodes.fontRegistered() } }
        return true
    }

    /// A REGISTERED face for (family, weight, style) at `size`, nil for a family the app did not
    /// register (the canvas painter then resolves the platform's own).
    public static func registeredFont(family: String, weight: Int, italic: Bool, size: CGFloat) -> UIFont? {
        guard !family.isEmpty else { return nil }
        lock.lock()
        let registered = fonts[key(family, weight, italic ? 2 : 0)] ?? fonts[key(family, weight, 0)]
        lock.unlock()
        guard let registered, let name = registered.postScriptName as String? else { return nil }
        return UIFont(name: name, size: size)
    }

    /// The face for (family, weight, style) at `size`: a registered one, else the system fallback.
    public static func font(family: String, weight: Int, italic: Bool, size: CGFloat) -> UIFont {
        if let f = registeredFont(family: family, weight: weight, italic: italic, size: size) { return f }
        let w = uiWeight(weight)
        let base: UIFont
        switch family.lowercased() {
        case "monospace", "monospaced", "ui-monospace": base = .monospacedSystemFont(ofSize: size, weight: w)
        case "serif", "ui-serif":
            let d = UIFont.systemFont(ofSize: size, weight: w).fontDescriptor.withDesign(.serif)
            base = d.map { UIFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size, weight: w)
        default: base = .systemFont(ofSize: size, weight: w)
        }
        return italic ? italicized(base) : base
    }

    static func uiWeight(_ weight: Int) -> UIFont.Weight {
        switch weight {
        case ..<150: return .ultraLight
        case 150..<250: return .thin
        case 250..<350: return .light
        case 350..<450: return .regular
        case 450..<550: return .medium
        case 550..<650: return .semibold
        case 650..<750: return .bold
        case 750..<850: return .heavy
        default: return .black
        }
    }

    static func italicized(_ font: UIFont) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        traits.insert(.traitItalic)
        guard let d = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: d, size: font.pointSize)
    }
}

/// Every live text node, weakly: a registered face reaches all of them (the ones on covered roots
/// too — both the fallback and its cached measure are stale).
enum TextNodes {
    private static var nodes: [ObjectIdentifier: Weak] = [:]
    private struct Weak { weak var node: UINode? }

    static func add(_ n: UINode) { nodes[ObjectIdentifier(n)] = Weak(node: n) }
    static func remove(_ n: UINode) { nodes[ObjectIdentifier(n)] = nil }

    /// A face landed: re-resolve and re-measure every text-bearing node. Main thread.
    public static func fontRegistered() {
        for (k, w) in nodes {
            guard let n = w.node, !n.isRemoved else { nodes[k] = nil; continue }
            (n as? UINodeText)?.fontChanged()
            (n as? UINodeInput)?.fontChanged()
        }
    }
}
