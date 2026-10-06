// AUTO-GENERATED from engines/ui/properties.mjs — DO NOT EDIT. Regenerate: bun run gen:ui-props
//
// The CUIPaint record layout (engines/ui/include/creator-ui/paint.gen.h) for a reader over the
// record's memory (little-endian, 4-byte words): word offsets, mask bits, enum codes.

public enum CuiPaint {
    public static let words = 78
    public static let bytes = 312
    public static let presentLo = 0, presentHi = 1, dirtyLo = 2, dirtyHi = 3

    public enum Bit {
        public static let display = 0
        public static let overflow = 1
        public static let scrollDirection = 2
        public static let borderWidth = 3
        public static let borderTopWidth = 4
        public static let borderRightWidth = 5
        public static let borderBottomWidth = 6
        public static let borderLeftWidth = 7
        public static let borderHorizontalWidth = 8
        public static let borderVerticalWidth = 9
        public static let borderStartWidth = 10
        public static let borderEndWidth = 11
        public static let color = 12
        public static let backgroundColor = 13
        public static let borderColor = 14
        public static let borderTopColor = 15
        public static let borderRightColor = 16
        public static let borderBottomColor = 17
        public static let borderLeftColor = 18
        public static let placeholderColor = 19
        public static let refreshControlColor = 20
        public static let tintColor = 21
        public static let rippleColor = 22
        public static let overlayColor = 23
        public static let backgroundImage = 24
        public static let backgroundSize = 25
        public static let backgroundGradient = 26
        public static let borderRadius = 27
        public static let borderTopLeftRadius = 28
        public static let borderTopRightRadius = 29
        public static let borderBottomRightRadius = 30
        public static let borderBottomLeftRadius = 31
        public static let opacity = 32
        public static let transform = 33
        public static let transformOrigin = 34
        public static let pointerEvents = 35
        public static let fontSize = 36
        public static let fontWeight = 37
        public static let fontStyle = 38
        public static let fontFamily = 39
        public static let lineHeight = 40
        public static let letterSpacing = 41
        public static let textAlign = 42
        public static let textDecoration = 43
        public static let lineClamp = 44
        public static let textOverflow = 45
        public static let objectFit = 46
        public static let placeholder = 47
        public static let type = 48
        public static let enterKey = 49
        public static let autocapitalize = 50
        public static let autocorrect = 51
        public static let maxLength = 52
        public static let keyboardShrink = 53
        public static let keyboardDismiss = 54
        public static let showScrollbar = 55
        public static let overscrollMode = 56
        public static let keyboardDismissMode = 57
        public static let snap = 58
        public static let sheetDetents = 59
        public static let sheetDetent = 60
        public static let sheetDismissible = 61
        public static let dim = 62
    }

    public enum Word {
        public static let display = 4
        public static let overflow = 5
        public static let scrollDirection = 6
        public static let borderWidth = 7
        public static let borderTopWidth = 8
        public static let borderRightWidth = 9
        public static let borderBottomWidth = 10
        public static let borderLeftWidth = 11
        public static let borderHorizontalWidth = 12
        public static let borderVerticalWidth = 13
        public static let borderStartWidth = 14
        public static let borderEndWidth = 15
        public static let color = 16
        public static let backgroundColor = 17
        public static let borderColor = 18
        public static let borderTopColor = 19
        public static let borderRightColor = 20
        public static let borderBottomColor = 21
        public static let borderLeftColor = 22
        public static let placeholderColor = 23
        public static let refreshControlColor = 24
        public static let tintColor = 25
        public static let rippleColor = 26
        public static let overlayColor = 27
        public static let backgroundImage = 28
        public static let backgroundSize = 29
        public static let backgroundGradient = 30
        public static let borderRadius = 31
        public static let borderTopLeftRadius = 32
        public static let borderTopRightRadius = 33
        public static let borderBottomRightRadius = 34
        public static let borderBottomLeftRadius = 35
        public static let opacity = 36
        public static let transform = 37
        public static let transformOrigin = 46
        public static let pointerEvents = 50
        public static let fontSize = 51
        public static let fontWeight = 52
        public static let fontStyle = 53
        public static let fontFamily = 54
        public static let lineHeight = 55
        public static let letterSpacing = 56
        public static let textAlign = 57
        public static let textDecoration = 58
        public static let lineClamp = 59
        public static let textOverflow = 60
        public static let objectFit = 61
        public static let placeholder = 62
        public static let type = 63
        public static let enterKey = 64
        public static let autocapitalize = 65
        public static let autocorrect = 66
        public static let maxLength = 67
        public static let keyboardShrink = 68
        public static let keyboardDismiss = 69
        public static let showScrollbar = 70
        public static let overscrollMode = 71
        public static let keyboardDismissMode = 72
        public static let snap = 73
        public static let sheetDetents = 74
        public static let sheetDetent = 75
        public static let sheetDismissible = 76
        public static let dim = 77
    }

    public enum Display: UInt32 {
        case flex = 0, none = 1
    }
    public enum Overflow: UInt32 {
        case visible = 0, hidden = 1, scroll = 2
    }
    public enum ScrollDirection: UInt32 {
        case vertical = 0, horizontal = 1, all = 2
    }
    public enum BackgroundSize: UInt32 {
        case cover = 0, contain = 1, fill = 2, tile = 3
    }
    public enum PointerEvents: UInt32 {
        case all = 0, none = 1
    }
    public enum FontStyle: UInt32 {
        case normal = 0, italic = 1
    }
    public enum TextAlign: UInt32 {
        case start = 0, center = 1, end = 2, left = 3, right = 4
    }
    public enum TextDecoration: UInt32 {
        case underline = 0, line_through = 1, none = 2
    }
    public enum TextOverflow: UInt32 {
        case ellipsis = 0, clip = 1
    }
    public enum ObjectFit: UInt32 {
        case cover = 0, contain = 1, fill = 2
    }
    public enum InputType: UInt32 {
        case text = 0, password = 1, tel = 2, email = 3, number = 4, decimal = 5, url = 6, search = 7, date = 8, time = 9
    }
    public enum EnterKey: UInt32 {
        case done = 0, go = 1, next = 2, search = 3, send = 4
    }
    public enum Autocapitalize: UInt32 {
        case none = 0, sentences = 1, words = 2, characters = 3
    }
    public enum OverscrollMode: UInt32 {
        case `default` = 0, none = 1, absorb = 2
    }
    public enum KeyboardDismissMode: UInt32 {
        case interactive = 0, scroll = 1, none = 2
    }
    public enum Snap: UInt32 {
        case none = 0, start = 1, center = 2, end = 3
    }

    /// The registry spelling of each enum code, by field.
    public enum Names {
        public static let display = ["flex", "none"]
        public static let overflow = ["visible", "hidden", "scroll"]
        public static let scrollDirection = ["vertical", "horizontal", "all"]
        public static let backgroundSize = ["cover", "contain", "fill", "tile"]
        public static let pointerEvents = ["all", "none"]
        public static let fontStyle = ["normal", "italic"]
        public static let textAlign = ["start", "center", "end", "left", "right"]
        public static let textDecoration = ["underline", "line-through", "none"]
        public static let textOverflow = ["ellipsis", "clip"]
        public static let objectFit = ["cover", "contain", "fill"]
        public static let type = ["text", "password", "tel", "email", "number", "decimal", "url", "search", "date", "time"]
        public static let enterKey = ["done", "go", "next", "search", "send"]
        public static let autocapitalize = ["none", "sentences", "words", "characters"]
        public static let overscrollMode = ["default", "none", "absorb"]
        public static let keyboardDismissMode = ["interactive", "scroll", "none"]
        public static let snap = ["none", "start", "center", "end"]
    }

    public static func has(_ lo: UInt32, _ hi: UInt32, _ bit: Int) -> Bool {
        bit < 32 ? (lo >> UInt32(bit)) & 1 == 1 : (hi >> UInt32(bit - 32)) & 1 == 1
    }
}
