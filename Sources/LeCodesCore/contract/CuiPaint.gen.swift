// AUTO-GENERATED from engines/ui/properties.mjs — DO NOT EDIT. Regenerate: bun run gen:ui-props
//
// The CUIPaint record layout (engines/ui/include/creator-ui/paint.gen.h) for a reader over the
// record's memory (little-endian, 4-byte words): word offsets, mask bits, enum codes.

public enum CuiPaint {
    public static let words = 92
    public static let bytes = 368
    /// The masks' first words (128 bits = 4 words each; bit f in word f >> 5, bit f & 31).
    public static let presentAt = 0, dirtyAt = 4, maskWords = 4

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
        public static let zIndex = 35
        public static let pointerEvents = 36
        public static let fontSize = 37
        public static let fontWeight = 38
        public static let fontStyle = 39
        public static let fontFamily = 40
        public static let lineHeight = 41
        public static let letterSpacing = 42
        public static let textAlign = 43
        public static let textDecoration = 44
        public static let lineClamp = 45
        public static let textOverflow = 46
        public static let textWrap = 47
        public static let objectFit = 48
        public static let placeholder = 49
        public static let type = 50
        public static let enterKey = 51
        public static let autocapitalize = 52
        public static let autocorrect = 53
        public static let maxLength = 54
        public static let keyboardShrink = 55
        public static let keyboardDismiss = 56
        public static let showScrollbar = 57
        public static let overscrollMode = 58
        public static let keyboardDismissMode = 59
        public static let snap = 60
        public static let sheetDetents = 61
        public static let sheetDetent = 62
        public static let sheetDismissible = 63
        public static let dim = 64
        public static let backdropBlur = 65
        public static let glass = 66
        public static let boxShadow = 67
    }

    public enum Word {
        public static let display = 8
        public static let overflow = 9
        public static let scrollDirection = 10
        public static let borderWidth = 11
        public static let borderTopWidth = 12
        public static let borderRightWidth = 13
        public static let borderBottomWidth = 14
        public static let borderLeftWidth = 15
        public static let borderHorizontalWidth = 16
        public static let borderVerticalWidth = 17
        public static let borderStartWidth = 18
        public static let borderEndWidth = 19
        public static let color = 20
        public static let backgroundColor = 21
        public static let borderColor = 22
        public static let borderTopColor = 23
        public static let borderRightColor = 24
        public static let borderBottomColor = 25
        public static let borderLeftColor = 26
        public static let placeholderColor = 27
        public static let refreshControlColor = 28
        public static let tintColor = 29
        public static let rippleColor = 30
        public static let overlayColor = 31
        public static let backgroundImage = 32
        public static let backgroundSize = 33
        public static let backgroundGradient = 34
        public static let borderRadius = 35
        public static let borderTopLeftRadius = 36
        public static let borderTopRightRadius = 37
        public static let borderBottomRightRadius = 38
        public static let borderBottomLeftRadius = 39
        public static let opacity = 40
        public static let transform = 41
        public static let transformOrigin = 54
        public static let zIndex = 58
        public static let pointerEvents = 59
        public static let fontSize = 60
        public static let fontWeight = 61
        public static let fontStyle = 62
        public static let fontFamily = 63
        public static let lineHeight = 64
        public static let letterSpacing = 65
        public static let textAlign = 66
        public static let textDecoration = 67
        public static let lineClamp = 68
        public static let textOverflow = 69
        public static let textWrap = 70
        public static let objectFit = 71
        public static let placeholder = 72
        public static let type = 73
        public static let enterKey = 74
        public static let autocapitalize = 75
        public static let autocorrect = 76
        public static let maxLength = 77
        public static let keyboardShrink = 78
        public static let keyboardDismiss = 79
        public static let showScrollbar = 80
        public static let overscrollMode = 81
        public static let keyboardDismissMode = 82
        public static let snap = 83
        public static let sheetDetents = 84
        public static let sheetDetent = 85
        public static let sheetDismissible = 86
        public static let dim = 87
        public static let backdropBlur = 88
        public static let glass = 89
        public static let boxShadow = 90
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
    public enum TextWrap: UInt32 {
        case wrap = 0, nowrap = 1, balance = 2, pretty = 3
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
    public enum Glass: UInt32 {
        case none = 0, regular = 1, clear = 2
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
        public static let textWrap = ["wrap", "nowrap", "balance", "pretty"]
        public static let objectFit = ["cover", "contain", "fill"]
        public static let type = ["text", "password", "tel", "email", "number", "decimal", "url", "search", "date", "time"]
        public static let enterKey = ["done", "go", "next", "search", "send"]
        public static let autocapitalize = ["none", "sentences", "words", "characters"]
        public static let overscrollMode = ["default", "none", "absorb"]
        public static let keyboardDismissMode = ["interactive", "scroll", "none"]
        public static let snap = ["none", "start", "center", "end"]
        public static let glass = ["none", "regular", "clear"]
    }

    /// present / dirty bit test: `at` = the mask's first word (presentAt / dirtyAt) from the record's base.
    public static func has(_ base: UnsafePointer<UInt32>, _ at: Int, _ bit: Int) -> Bool {
        (base[at + (bit >> 5)] >> UInt32(bit & 31)) & 1 == 1
    }
}
