// Shared wire plumbing of the two plugin channels (registerView's viewCall and registerService's
// call). The wire carries VALUES. A GENERATED half reads its contract's structs straight out of the
// runtime's value and writes them straight into one (WireIn / WireOut of LeCodesCore); a half
// written by hand takes its arguments as the Foundation objects a JSON reader would make of them —
// plus `Data` for bytes — and answers the same way (an omitted result is `undefined` on the JS
// side). Only a view's / a service's PARAMS are JSON text: they are part of the tree. Errors are
// plain strings. The settle pair is a runtime callback pair the host settles EXACTLY once, from
// any thread.
import Foundation
import LeCodesCore

/// A value of the wire as the generated code reads it, and where it writes one. The names a
/// generated file uses: it imports this module alone.
public typealias WireIn = LeCodesCore.WireIn
public typealias WireOut = LeCodesCore.WireOut

/// What a channel is handed, as its halves take it.
enum ChannelValues {
    /// The PARAMS of a view / a service: the one thing of a channel that is JSON text (they are part
    /// of the tree). Empty / absent → nil.
    static func params(_ json: String?) -> Any? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    /// A call's arguments as a half written by hand takes them: always an array.
    static func args(_ wire: WireIn) -> [Any] { (WireValue.read(wire) as? [Any]) ?? [] }
}

/// The settle handle of one channel call — the resolve / reject pair a plugin instance completes
/// from any thread (an AVCapture photo callback). Settles at most once.
public final class ChannelSettle {
    private let onComplete: JSCallback
    private let onError: JSCallback
    private let lock = NSLock()
    private var settled = false

    init(_ onComplete: JSCallback, _ onError: JSCallback) {
        self.onComplete = onComplete
        self.onError = onError
    }

    /// Resolve the call. `result` is data (a dictionary / array / String / number / Bool / Data,
    /// NSNull for a null) or nil, which the SDK surfaces as `undefined`.
    public func resolve(_ result: Any? = nil) {
        guard take() else { return }
        if let result { Core.resolve(onComplete, reject: onError) { $0.json(result) } }
        else { Core.resolve(onComplete, reject: onError) }
    }

    /// Resolve the call with the value `write` writes; nothing written = `undefined`.
    public func resolve(writing write: (WireOut) -> Void) {
        guard take() else { return }
        Core.resolve(onComplete, reject: onError, writing: write)
    }

    /// The channel's errors are plain strings (`onError(message)`), not Error objects.
    public func reject(_ message: String) {
        guard take() else { return }
        Core.call(onError, [.string(message)])
        Core.free(onComplete)
    }

    private func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if settled { return false }
        settled = true
        return true
    }
}
