// The `input` table (input.d.ts): the keyboard inset pull. A touch-only host has no buttons, no
// pointer channels and no pads yet (GameController pads are a later addition), so every other
// slot stays nil and the SDK reads "nothing held, zero motion". The push side
// (Core.emitKeyboardEvent) is the view layer's, after it wrote `engine.keyboardHeight`.
import Foundation
import LeCodesCore

final class InputHost: HostInput {
    weak var engine: LeCodesEngine?
    var keyboardHeight: (() -> Double)? { { [weak self] in Double(self?.engine?.keyboardHeight ?? 0) } }
}
