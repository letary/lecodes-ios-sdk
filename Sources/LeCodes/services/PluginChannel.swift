// What a GENERATED plugin half stands on (`lecodes plugin gen` → `<Name>.gen.swift`,
// docs/plans/plugins-plan.md): the typed reply of one call and the file a half hands over. A
// plugin's own code names `Reply` and `PluginFile`.
//
// The wire's FORMAT is known to the generated glue, never to a plugin. It carries VALUES, and the
// glue reads a contract's struct straight out of the runtime's value and writes one straight into
// it (WireIn / WireOut of LeCodesCore): no tree of Foundation's objects, no text in between.
import Foundation

/// The codes a channel's calls reject with (`@rejects` in the contract): a generated enum per channel.
public protocol PluginCode {
    var code: String { get }
}

public extension PluginCode where Self: RawRepresentable, RawValue == String {
    var code: String { rawValue }
}

/// The codes of a channel whose contract names none.
public enum NoCode: PluginCode {
    public var code: String { switch self {} }
}

/// The reply of one call. Settle it EXACTLY once, now or later, from any thread; a second settle is
/// dropped.
public final class Reply<Value, Code: PluginCode> {
    private let settle: ChannelSettle
    private let write: ((Value, WireOut) -> Void)?

    /// `write` puts the value on the wire; writing nothing leaves the app with `undefined`.
    public init(_ settle: ChannelSettle, _ write: @escaping (Value, WireOut) -> Void) {
        self.settle = settle
        self.write = write
    }

    /// The reply of a call that answers with no value.
    public init(_ settle: ChannelSettle) where Value == Void {
        self.settle = settle
        self.write = nil
    }

    public func resolve(_ value: Value) {
        guard let write else { return settle.resolve() }
        settle.resolve { write(value, $0) }
    }

    /// Fail with a code of the contract — the app's promise rejects with it as the message.
    public func reject(_ code: Code) { settle.reject(code.code) }

    /// Fail with a message the contract has no code for (a bug, a state that should not be).
    public func fail(_ message: String) { settle.reject(message) }
}

public extension Reply where Value == Void {
    func resolve() { resolve(()) }
}

/// A `File` of the contract. One a half hands to the app: its bytes go into the host's buffer
/// table, the app gets the handle (a texture source, an upload, a share) and the bytes never enter
/// the JS heap. One the app hands to a half: the bytes of the buffer its handle names.
public struct PluginFile {
    public var data: Data
    public var name: String

    public init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    /// The handle as it crosses: the buffer is stored HERE, once per write.
    public func write(to out: WireOut) {
        out.beginObject(3)
        out.key("systemId"); out.i32(Buffers.add(data))
        out.key("name"); out.string(name)
        out.key("size"); out.i32(Int32(clamping: data.count))
        out.end()
    }
}

public extension WireIn {
    /// A File the app handed over: its handle names a buffer of the host's table. nil when it is
    /// not a handle, or the buffer is gone.
    var file: PluginFile? {
        guard let id = self["systemId", 0].i32, let data = Buffers.get(id) else { return nil }
        return PluginFile(data: data, name: self["name", 1].string ?? "")
    }
}
