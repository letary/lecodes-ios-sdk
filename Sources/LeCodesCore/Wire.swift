// The wire of a plugin channel as the code of a half reads and writes it, with NOTHING in between:
// a contract's struct is read straight out of the runtime's value (WireIn, over the C face's
// lc_value*) and written straight into one (WireOut, over its builder lc_values*). The GENERATED
// half of a plugin does both (`lecodes plugin gen`); a half written by hand takes Foundation's
// objects instead, which WireValue (LeValue.swift) makes of the same value.
//
// The data is JSON's, plus bytes: a number that is not finite is a null, either way.
import Foundation
import CLeCodesCore

/// LC_VALUE_* of lecodes-core.h (an anonymous C enum: spelled out here, not imported).
enum WireKind {
    static let null: Int32 = 0, bool: Int32 = 1, int: Int32 = 2, double: Int32 = 3, string: Int32 = 4
    static let bytes: Int32 = 5, array: Int32 = 6, object: Int32 = 7
}

/// A value the runtime handed over: a call's arguments, or one value inside them. Valid ONLY inside
/// the call that handed it over — what is read out of it is a copy. A reader answers nil for
/// absent, null, or not that type.
public struct WireIn {
    /// LeValueRef; nil = absent (an argument the caller left out, a member the object has not).
    let ref: OpaquePointer?

    public init(_ ref: OpaquePointer?) { self.ref = ref }

    /// Is there a value — neither absent nor null?
    public var isPresent: Bool { lc_valueKind(ref) != WireKind.null }

    public var bool: Bool? { lc_valueKind(ref) == WireKind.bool ? lc_valueBool(ref) : nil }

    public var f64: Double? {
        switch lc_valueKind(ref) {
        case WireKind.int: return Double(lc_valueInt(ref))
        case WireKind.double:
            let d = lc_valueDouble(ref)
            return d.isFinite ? d : nil
        default: return nil
        }
    }

    public var i32: Int32? {
        switch lc_valueKind(ref) {
        case WireKind.int: return lc_valueInt(ref)
        case WireKind.double:
            let d = lc_valueDouble(ref)
            guard d == d.rounded(), d >= Double(Int32.min), d <= Double(Int32.max) else { return nil }
            return Int32(d)
        default: return nil
        }
    }

    public var string: String? {
        guard lc_valueKind(ref) == WireKind.string else { return nil }
        var length = 0
        return WireIn.text(lc_valueString(ref, &length), length)
    }

    /// The bytes of a Uint8Array.
    public var bytes: Data? {
        guard lc_valueKind(ref) == WireKind.bytes else { return nil }
        var count = 0
        guard let p = lc_valueBytes(ref, &count), count > 0 else { return Data() }
        return Data(bytes: p, count: count)
    }

    /// Any JSON value, as Foundation's objects; a null is a value here (NSNull), only an absent one
    /// is nil. What the contract calls Json IS JSON for the half — it may hand it to
    /// JSONSerialization, which RAISES on what JSON cannot say — so the bytes the wire carries
    /// beyond JSON are null in it.
    public var json: Any? {
        guard let ref else { return nil }
        return WireValue.object(ref, bytes: false)
    }

    public var isObject: Bool { lc_valueKind(ref) == WireKind.object }

    /// The elements of an array, the members of an object; 0 for anything else.
    public var count: Int { lc_valueCount(ref) }

    /// An element of an array; absent past its end.
    public subscript(index: Int) -> WireIn { WireIn(lc_valueAt(ref, index)) }

    /// A member of an object by its name; absent when it has none. `hint` = the member's place in
    /// its struct, where the look starts.
    public subscript(key: StaticString, hint: Int = 0) -> WireIn {
        key.withUTF8Buffer { k in
            k.withMemoryRebound(to: CChar.self) { WireIn(lc_valueMember(ref, $0.baseAddress, $0.count, hint)) }
        }
    }

    /// The array itself when it holds exactly `count` values (a tuple).
    public func tuple(_ count: Int) -> WireIn? {
        lc_valueKind(ref) == WireKind.array && lc_valueCount(ref) == count ? self : nil
    }

    /// Every element or nothing: one that does not read fails the list.
    public func list<T>(_ each: (WireIn) -> T?) -> [T]? {
        guard lc_valueKind(ref) == WireKind.array else { return nil }
        let n = lc_valueCount(ref)
        var out: [T] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let value = each(WireIn(lc_valueAt(ref, i))) else { return nil }
            out.append(value)
        }
        return out
    }

    /// The members of an object, each read the same way.
    public func map<T>(_ each: (WireIn) -> T?) -> [String: T]? {
        guard lc_valueKind(ref) == WireKind.object else { return nil }
        let n = lc_valueCount(ref)
        var out: [String: T] = [:]
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let value = each(WireIn(lc_valueAt(ref, i))) else { return nil }
            var length = 0
            out[WireIn.text(lc_valueKeyAt(ref, i, &length), length)] = value
        }
        return out
    }

    /// `value` — Foundation's objects, what a JSON reader makes (the PARAMS of a view / a service,
    /// which are text in the tree) — as a value of the wire, for the time of `body`.
    public static func of<T>(_ value: Any?, _ body: (WireIn) -> T) -> T {
        guard let value else { return body(WireIn(nil)) }
        return WireOut.written({ $0.json(value) }, body)
    }

    /// `length` bytes of UTF-8 (a NUL may sit inside: never a C string).
    static func text(_ p: UnsafePointer<CChar>?, _ length: Int) -> String {
        guard let p, length > 0 else { return "" }
        return p.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }
}

/// Where a result or an event's payload is written: the runtime's value, member by member, as the
/// calls come. Inside an object every value follows its `key`. Nothing written = no value (the app
/// sees `undefined`).
public struct WireOut {
    /// LcValues*: the builder the dispatch consumes.
    let values: OpaquePointer

    init(_ values: OpaquePointer) { self.values = values }

    public func null() { lc_valuesNull(values) }
    public func bool(_ b: Bool) { lc_valuesBool(values, b) }
    public func i32(_ i: Int32) { lc_valuesInt(values, i) }
    /// A number that is not finite leaves as null, which is what `JSON.stringify` makes of it.
    public func f64(_ d: Double) { if d.isFinite { lc_valuesDouble(values, d) } else { lc_valuesNull(values) } }

    public func string(_ s: String) {
        var s = s
        s.withUTF8 { $0.withMemoryRebound(to: CChar.self) { lc_valuesText(values, $0.baseAddress, $0.count) } }   // by length: a NUL may sit inside
    }

    /// Reaches the app as a Uint8Array.
    public func bytes(_ d: Data) {
        d.withUnsafeBytes { lc_valuesBytes(values, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
    }

    /// Foundation's objects — a Json member, a result a half written by hand answers with — member
    /// by member. nil and NSNull are null; `Data` is bytes; what is not data is null.
    public func json(_ value: Any?) {
        guard let value else { return null() }
        switch value {
        case is NSNull: null()
        case let s as String: string(s)
        case let d as Data: bytes(d)
        // Bytes are what was MADE as bytes. An array the JSON reader made of small whole numbers
        // (`[10, 30]`) casts to [UInt8] too — it is an array of numbers, and is written as one.
        case let b as [UInt8] where type(of: value) == [UInt8].self:
            b.withUnsafeBufferPointer { lc_valuesBytes(values, $0.baseAddress, $0.count) }
        case let n as NSNumber:
            // A boolean is an NSNumber too: told apart by the CF type, as JSONSerialization does.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { bool(n.boolValue) } else { f64(n.doubleValue) }
        case let a as [Any]:
            beginArray(a.count)
            for item in a { json(item) }
            end()
        case let o as [String: Any]:
            beginObject(o.count)
            for (k, item) in o { name(k); json(item) }
            end()
        default: null()
        }
    }

    /// `count` = how many elements follow (room is made for them; more or fewer is no error).
    public func beginArray(_ count: Int = 0) {
        lc_valuesBeginArray(values)
        if count > 0 { lc_valuesReserve(values, count) }
    }

    public func beginObject(_ count: Int = 0) {
        lc_valuesBeginObject(values)
        if count > 0 { lc_valuesReserve(values, count) }
    }

    public func end() { lc_valuesEnd(values) }

    /// The key of the next value: a member's name, known where the code was written.
    public func key(_ key: StaticString) {
        key.withUTF8Buffer { k in
            k.withMemoryRebound(to: CChar.self) { lc_valuesKeyText(values, $0.baseAddress, $0.count) }
        }
    }

    /// The key of the next value: one that is data (a map's).
    public func name(_ key: String) {
        var key = key
        key.withUTF8 { $0.withMemoryRebound(to: CChar.self) { lc_valuesKeyText(values, $0.baseAddress, $0.count) } }
    }

    /// A builder `write` filled; nil when it wrote nothing. The caller hands it to a dispatch,
    /// which consumes it.
    static func builder(_ write: (WireOut) -> Void) -> OpaquePointer? {
        let v = lc_valuesNew()!
        write(WireOut(v))
        if lc_valuesCount(v) == 0 { lc_valuesFree(v); return nil }
        return v
    }

    /// What `write` wrote, read back for the time of `body` (absent when it wrote nothing): the
    /// params of a channel, a test.
    public static func written<T>(_ write: (WireOut) -> Void, _ body: (WireIn) -> T) -> T {
        let v = lc_valuesNew()!
        defer { lc_valuesFree(v) }
        write(WireOut(v))
        return body(WireIn(lc_valuesAt(v, 0)))
    }
}
