// The input's views — the old host's NodeInput (a UITextField) and NodeTextArea (a UITextView),
// lifted onto the contract. The value rides the content channel ("value", "focus" = "1" / "0"),
// the style the paint record (the text style, placeholder + placeholderColor, type, enterKey,
// maxLength, autocapitalize, autocorrect, keyboardShrink / keyboardDismiss); the events go back by
// id gated on the flags — CHANGE (the value), SUBMIT (the return key), FOCUS / BLUR — posted
// (user JS never runs inside a UIKit editing transaction), with CreatorUI.setNodeFocused flipping
// the core's focused layer synchronously. `type: date | time` swaps the keyboard for a UIDatePicker
// in the keyboard's slot (the whole focus / shrink / dismissal machinery applies unchanged): the
// WIRE value stays canonical ("yyyy-MM-dd" / "HH:mm") while the field displays a localized string.
// A returnless pad (number / decimal / phone / the pickers) gets a Done bar — without it the
// keyboard could only be dismissed by tapping outside. The padding is the core's (the yoga
// padding), never the control's. The measure: an input is one text line; a textarea follows its
// content (the core clamps through minHeight / maxHeight, past which the view scrolls inside).
import LeCodesCore
import UIKit

/// The renderer's defaults of a field with no style of its own (docs/tree.md: "an input's black" — fixed,
/// as Android, tgfx and the web have it; the theme's `text` is what adapts, and it arrives in the record).
/// The gray is the same in light and dark (unlike UIKit's `.placeholderText`, which follows the SYSTEM
/// appearance, not the app's theme — 30% dark gray on a dark app's field).
enum InputDefaults {
    static let textColor = UIColor.black
    static let placeholderColor = UIColor.systemGray
}

/// What both controls share: the value, the focus, the traits.
protocol InputControl: UIView {
    var textValue: String { get }
    func setValue(_ value: String)
    func setFocused(_ focused: Bool)
    func applyFont(_ font: UIFont)
    /// The record's line box (always set: the core resolves `normal` = fontSize × 1.2): an input is
    /// one line of it tall, a textarea N lines — the desktop's and the web's model.
    func applyLineHeight(_ value: CGFloat)
    func applyTextColor(_ color: UIColor)
    func applyPlaceholder(_ text: String?, color: UIColor?)
    func applyTextAlign(_ align: NSTextAlignment)
    func applyInputType(_ type: CuiPaint.InputType)
    func applyEnterKey(_ key: CuiPaint.EnterKey?)
    func applyAutocapitalize(_ value: CuiPaint.Autocapitalize)
    func applyAutocorrect(_ on: Bool)
    var maxLength: Int? { get set }
    var padding: UIEdgeInsets { get set }
    func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize
}

final class InputFieldView: UITextField, UITextFieldDelegate, InputControl {
    weak var node: UINodeInput?
    var padding = UIEdgeInsets.zero { didSet { setNeedsLayout() } }
    var maxLength: Int?
    private var inputType: CuiPaint.InputType = .text
    private var enterKey: CuiPaint.EnterKey?

    init(node: UINodeInput) {
        self.node = node
        super.init(frame: .zero)
        delegate = self
        textColor = InputDefaults.textColor
        font = .systemFont(ofSize: 14)
        addTarget(self, action: #selector(editingChanged), for: .editingChanged)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        node?.box.layoutSublayers()
    }

    // MARK: - InputControl

    var textValue: String { isPickerKind ? (pickerValue ?? "") : (text ?? "") }
    func setValue(_ value: String) {
        if isPickerKind { setCanonicalValue(value) } else { text = value }
    }
    func setFocused(_ focused: Bool) {
        if focused { becomeFirstResponder() } else if isFirstResponder { resignFirstResponder() }
    }
    func applyFont(_ f: UIFont) { font = f }
    private var lineHeight: CGFloat = 14 * 1.2   // the core's fresh-node record until the first paint sync
    func applyLineHeight(_ value: CGFloat) { lineHeight = value }
    func applyTextColor(_ c: UIColor) { textColor = c }
    private var placeholderText: String?
    private var placeholderTint: UIColor?
    /// nil = no placeholder; a reset has to CLEAR the existing one.
    func applyPlaceholder(_ text: String?, color: UIColor?) {
        placeholderText = text
        placeholderTint = color
        guard let text, !text.isEmpty else { attributedPlaceholder = nil; placeholder = nil; return }
        attributedPlaceholder = NSAttributedString(string: text, attributes: [.foregroundColor: color ?? InputDefaults.placeholderColor])
    }
    func applyTextAlign(_ a: NSTextAlignment) { textAlignment = a }
    /// Keyboard HINTS only — no validation happens here.
    func applyInputType(_ type: CuiPaint.InputType) {
        inputType = type
        isSecureTextEntry = type == .password
        switch type {
        case .tel: keyboardType = .phonePad
        case .email: keyboardType = .emailAddress
        case .number: keyboardType = .numberPad
        case .decimal: keyboardType = .decimalPad
        case .url: keyboardType = .URL
        default: keyboardType = .default
        }
        updatePickerInputView()
        updateAccessoryBar()
        applyReturnKey()
    }
    /// enterKey wins over the return key a type implies (search → .search).
    func applyEnterKey(_ key: CuiPaint.EnterKey?) {
        enterKey = key
        applyReturnKey()
    }
    private func applyReturnKey() {
        if let enterKey {
            switch enterKey {
            case .go: returnKeyType = .go
            case .next: returnKeyType = .next
            case .search: returnKeyType = .search
            case .send: returnKeyType = .send
            case .done: returnKeyType = .done
            }
        } else {
            returnKeyType = inputType == .search ? .search : .default
        }
        if isFirstResponder { reloadInputViews() }
    }
    func applyAutocapitalize(_ v: CuiPaint.Autocapitalize) {
        switch v {
        case .none: autocapitalizationType = .none
        case .words: autocapitalizationType = .words
        case .characters: autocapitalizationType = .allCharacters
        default: autocapitalizationType = .sentences
        }
        if isFirstResponder { reloadInputViews() }
    }
    func applyAutocorrect(_ on: Bool) {
        autocorrectionType = on ? .yes : .no
        spellCheckingType = on ? .yes : .no
        if isFirstResponder { reloadInputViews() }
    }

    /// One text line: an input with no explicit height is one line box (the record's lineHeight)
    /// tall instead of collapsing to the minHeight floor; the text centres in it (UITextField's
    /// own vertical centring). The core adds the padding back.
    func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        let line = ceil(lineHeight)
        let w: CGFloat = (widthMode == 0 || width.isNaN) ? 200 : CGFloat(width)
        let h: CGFloat = (heightMode == 1 && !height.isNaN) ? CGFloat(height) : line
        return CGSize(width: w, height: h)
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: padding) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: padding) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: padding) }

    // MARK: - the date / time picker kinds

    private var isPickerKind: Bool { inputType == .date || inputType == .time }
    private var datePicker: UIDatePicker?
    /// The canonical value ("yyyy-MM-dd" / "HH:mm"); nil = empty (the placeholder shows).
    private var pickerValue: String?
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }
    private static let isoDate = formatter("yyyy-MM-dd")
    private static let isoTime = formatter("HH:mm")
    private static let displayDate: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()
    private static let displayTime: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()

    private func updatePickerInputView() {
        if isPickerKind {
            let picker = datePicker ?? UIDatePicker()
            picker.datePickerMode = inputType == .date ? .date : .time
            picker.preferredDatePickerStyle = .wheels
            if datePicker == nil {
                picker.addTarget(self, action: #selector(pickerValueChanged), for: .valueChanged)
                datePicker = picker
            }
            inputView = picker
        } else if datePicker != nil {
            inputView = nil
            datePicker = nil
        }
        if isFirstResponder { reloadInputViews() }
    }
    @objc private func pickerValueChanged() {
        guard let picker = datePicker else { return }
        adoptPickerDate(picker.date)
    }
    private func adoptPickerDate(_ date: Date) {
        let canonical = inputType == .date ? InputFieldView.isoDate.string(from: date) : InputFieldView.isoTime.string(from: date)
        guard canonical != pickerValue else { return }
        pickerValue = canonical
        text = inputType == .date ? InputFieldView.displayDate.string(from: date) : InputFieldView.displayTime.string(from: date)
        node?.dispatchChange(canonical)
    }
    private func parseCanonical(_ value: String) -> Date? {
        inputType == .date ? InputFieldView.isoDate.date(from: value) : InputFieldView.isoTime.date(from: value)
    }
    /// A programmatic set: canonical in → localized display out; malformed values are ignored.
    private func setCanonicalValue(_ canonical: String) {
        if canonical.isEmpty { pickerValue = nil; text = ""; return }
        guard let date = parseCanonical(canonical) else { return }
        pickerValue = inputType == .date ? InputFieldView.isoDate.string(from: date) : InputFieldView.isoTime.string(from: date)
        text = inputType == .date ? InputFieldView.displayDate.string(from: date) : InputFieldView.displayTime.string(from: date)
        datePicker?.date = date
    }
    // No caret / selection / paste in a field the user cannot type into.
    override func caretRect(for position: UITextPosition) -> CGRect { isPickerKind ? .zero : super.caretRect(for: position) }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { isPickerKind ? [] : super.selectionRects(for: range) }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { isPickerKind ? false : super.canPerformAction(action, withSender: sender) }

    private func updateAccessoryBar() {
        let returnless = keyboardType == .numberPad || keyboardType == .decimalPad || keyboardType == .phonePad || isPickerKind
        if returnless {
            if inputAccessoryView == nil {
                let bar = UIToolbar()
                bar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                             UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(accessoryDone))]
                bar.sizeToFit()
                inputAccessoryView = bar
            }
        } else if inputAccessoryView != nil {
            inputAccessoryView = nil
        }
        if isFirstResponder { reloadInputViews() }
    }
    /// Done confirms the wheels even if untouched (open → Done = today); a dismissal by a tap in
    /// dead space or a drag does not adopt — that is the cancel gesture.
    @objc private func accessoryDone() {
        if isPickerKind, pickerValue == nil, let picker = datePicker { adoptPickerDate(picker.date) }
        resignFirstResponder()
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        node?.dispatchSubmit(textValue)
        // Submit dismisses the keyboard UNLESS enterKey == next — the app then moves the focus
        // itself, so the keyboard never blinks out and back.
        if enterKey != .next { textField.resignFirstResponder() }
        return true
    }
    /// maxLength. Never clip mid-IME composition (marked text): the final commit passes here again.
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if isPickerKind { return false }
        guard let maxLength, textField.markedTextRange == nil else { return true }
        let current = (textField.text ?? "") as NSString
        return current.length - range.length + (string as NSString).length <= maxLength
    }
    func textFieldDidBeginEditing(_ textField: UITextField) {
        if isPickerKind, let value = pickerValue, let date = parseCanonical(value) { datePicker?.date = date }
        node?.focusChanged(true)
    }
    func textFieldDidEndEditing(_ textField: UITextField) { node?.focusChanged(false) }
    @objc private func editingChanged() { node?.dispatchChange(text ?? "") }
}

final class TextAreaView: UITextView, UITextViewDelegate, InputControl {
    weak var node: UINodeInput?
    var padding = UIEdgeInsets.zero { didSet { textContainerInset = padding; setNeedsLayout() } }
    var maxLength: Int?
    private let placeholderLabel = UILabel()
    private var enterKey: CuiPaint.EnterKey?
    private var lineHeight: CGFloat = 14 * 1.2   // the core's fresh-node record until the first paint sync

    init(node: UINodeInput) {
        self.node = node
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        backgroundColor = .clear
        textColor = InputDefaults.textColor
        font = .systemFont(ofSize: 14)
        isScrollEnabled = true
        textContainer.lineFragmentPadding = 0
        textContainerInset = .zero
        placeholderLabel.numberOfLines = 0
        placeholderLabel.backgroundColor = .clear
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        node?.box.layoutSublayers()
        let x = textContainerInset.left, y = textContainerInset.top
        let width = max(0, bounds.width - textContainerInset.left - textContainerInset.right)
        let fit = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        placeholderLabel.place(CGRect(x: x + contentOffset.x, y: y + contentOffset.y, width: width, height: fit.height))
        placeholderLabel.isHidden = !text.isEmpty || (placeholderLabel.text ?? "").isEmpty
    }

    var textValue: String { text ?? "" }
    func setValue(_ value: String) {
        text = value
        stampParagraph()
        placeholderLabel.isHidden = !value.isEmpty || (placeholderLabel.text ?? "").isEmpty
        node.map { FrameBatcher.request($0, measure: true) }   // auto-grow re-measures on a programmatic set too
    }
    func setFocused(_ focused: Bool) {
        if focused { becomeFirstResponder() } else if isFirstResponder { resignFirstResponder() }
    }
    func applyFont(_ f: UIFont) { font = f; placeholderLabel.font = f; stampParagraph() }
    func applyTextColor(_ c: UIColor) { textColor = c }
    func applyPlaceholder(_ text: String?, color: UIColor?) {
        placeholderLabel.text = text
        placeholderLabel.textColor = color ?? InputDefaults.placeholderColor
        setNeedsLayout()
    }
    func applyTextAlign(_ a: NSTextAlignment) { textAlignment = a; placeholderLabel.textAlignment = a; stampParagraph() }
    func applyInputType(_ type: CuiPaint.InputType) {}
    func applyEnterKey(_ key: CuiPaint.EnterKey?) {
        enterKey = key
        switch key {
        case .go?: returnKeyType = .go
        case .next?: returnKeyType = .next
        case .search?: returnKeyType = .search
        case .send?: returnKeyType = .send
        case .done?: returnKeyType = .done
        case nil: returnKeyType = .default
        }
    }
    func applyAutocapitalize(_ v: CuiPaint.Autocapitalize) {
        switch v {
        case .none: autocapitalizationType = .none
        case .words: autocapitalizationType = .words
        case .characters: autocapitalizationType = .allCharacters
        default: autocapitalizationType = .sentences
        }
    }
    func applyAutocorrect(_ on: Bool) {
        autocorrectionType = on ? .yes : .no
        spellCheckingType = on ? .yes : .no
    }
    func applyLineHeight(_ value: CGFloat) {
        if value == lineHeight { return }
        lineHeight = value
        stampParagraph()
    }

    /// UITextView has no line-height property: a paragraph style with the exact line box stamped
    /// onto BOTH the storage and typingAttributes (so text typed next keeps it).
    private func stampParagraph() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        var attrs = typingAttributes
        attrs[.paragraphStyle] = paragraph
        typingAttributes = attrs
        textStorage.addAttributes([.paragraphStyle: paragraph], range: NSRange(location: 0, length: textStorage.length))
    }

    /// Content-driven height (auto-grow). Yoga speaks the CONTENT box, sizeThatFits the border box
    /// (it includes textContainerInset): the inset is added for the query, stripped from the result.
    func measure(width: Float, widthMode: UInt8, height: Float, heightMode: UInt8) -> CGSize {
        let inset = padding
        if textContainerInset != inset { textContainerInset = inset }
        let contentW: CGFloat = (widthMode == 0 || width.isNaN) ? 200 : CGFloat(width)
        let size = sizeThatFits(CGSize(width: contentW + inset.left + inset.right, height: .greatestFiniteMagnitude))
        let line = ceil(lineHeight)   // never shorter than one line box
        let h = max(line, size.height - inset.top - inset.bottom)
        return CGSize(width: contentW, height: (heightMode == 1 && !height.isNaN) ? CGFloat(height) : h)
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !text.isEmpty || (placeholderLabel.text ?? "").isEmpty
        node?.dispatchChange(text ?? "")
        node.map { FrameBatcher.request($0, measure: true) }
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText string: String) -> Bool {
        guard let maxLength, textView.markedTextRange == nil else { return true }
        let current = (textView.text ?? "") as NSString
        return current.length - range.length + (string as NSString).length <= maxLength
    }
    func textViewDidBeginEditing(_ textView: UITextView) { node?.focusChanged(true) }
    func textViewDidEndEditing(_ textView: UITextView) { node?.focusChanged(false) }
}
