// The arguments of a native → JS call: the Swift twin of the runtime's LeValue (creator-pkg.h), what
// Core.resolve / call / nodeEvent hand the dispatch queue. Built into the C face's LcValues builder
// (lecodes-core.h) at the call; literals make the common shapes read like JS:
//   Core.resolve(ok, reject: fail, [42, "text", true, nil, ["a", 1], ["status": 200, "body": bytes]])
import Foundation
import CLeCodesCore

public indirect enum LeValue {
    case null
    case bool(Bool)
    case int(Int32)
    case double(Double)
    case string(String)
    /// Reaches JS as a Uint8Array (its own copy).
    case bytes([UInt8])
    /// A JS Error (a reject reason).
    case error(String)
    case array([LeValue])
    /// Ordered keys, like the runtime's Object.
    case object([(String, LeValue)])

    /// Write this value into a builder (nested containers recurse).
    func write(into v: OpaquePointer) {
        switch self {
        case .null: lc_valuesNull(v)
        case .bool(let b): lc_valuesBool(v, b)
        case .int(let i): lc_valuesInt(v, i)
        case .double(let d): lc_valuesDouble(v, d)
        case .string(var s): s.withUTF8 { $0.withMemoryRebound(to: CChar.self) { lc_valuesText(v, $0.baseAddress, $0.count) } }   // by length: a NUL may sit inside
        case .bytes(let b): b.withUnsafeBufferPointer { lc_valuesBytes(v, $0.baseAddress, $0.count) }
        case .error(let m): lc_valuesError(v, m)
        case .array(let items):
            lc_valuesBeginArray(v)
            for item in items { item.write(into: v) }
            lc_valuesEnd(v)
        case .object(let entries):
            lc_valuesBeginObject(v)
            for (key, value) in entries { lc_valuesKey(v, key); value.write(into: v) }
            lc_valuesEnd(v)
        }
    }

    /// A builder holding `values` (consumed by the dispatch call it is handed to); nil for none.
    static func builder(_ values: [LeValue]) -> OpaquePointer? {
        if values.isEmpty { return nil }
        let v = lc_valuesNew()!
        for value in values { value.write(into: v) }
        return v
    }
}

extension LeValue: ExpressibleByNilLiteral { public init(nilLiteral: ()) { self = .null } }
extension LeValue: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension LeValue: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int32) { self = .int(value) } }
extension LeValue: ExpressibleByFloatLiteral { public init(floatLiteral value: Double) { self = .double(value) } }
extension LeValue: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension LeValue: ExpressibleByArrayLiteral { public init(arrayLiteral elements: LeValue...) { self = .array(elements) } }
extension LeValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, LeValue)...) { self = .object(elements) }
}

public extension LeValue {
    /// A number the way JS sees it: an Int32 when it is one, else a Double.
    static func number(_ d: Double) -> LeValue {
        if d == d.rounded(), abs(d) <= Double(Int32.max) { return .int(Int32(d)) }
        return .double(d)
    }
    /// `.string(s)` or `.null`.
    static func string(_ s: String?) -> LeValue { s.map { .string($0) } ?? .null }
}

/// A scalar JS passed to a registered host method (Core.registerCallback), and the scalar the host
/// answers with — what crosses the C face's LcScalar.
public enum LeScalar {
    case null
    case bool(Bool)
    case int(Int32)
    case double(Double)
    case string(String)
    /// A borrowed JS value (a function / object the host cannot read here).
    case jsValue(UnsafeMutableRawPointer)

    init(_ c: LcScalar) {
        switch Int(c.kind) {
        case 1: self = .bool(c.b)
        case 2: self = .int(c.i)
        case 3: self = .double(c.d)
        case 4: self = .string(c.s.map { String(cString: $0) } ?? "")
        case 5: self = c.p.map { .jsValue($0) } ?? .null
        default: self = .null
        }
    }

    /// The C scalar for a result: a string is strdup'd (the runtime frees it).
    var cScalar: LcScalar {
        var c = LcScalar()
        switch self {
        case .null: c.kind = 0
        case .bool(let b): c.kind = 1; c.b = b
        case .int(let i): c.kind = 2; c.i = i
        case .double(let d): c.kind = 3; c.d = d
        case .string(let s): c.kind = 4; c.s = UnsafePointer(strdup(s))
        case .jsValue(let p): c.kind = 5; c.p = p
        }
        return c
    }

    public var asString: String? { if case .string(let s) = self { return s } else { return nil } }
    public var asDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    public var asBool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
}

/// DATA between the runtime and a plugin channel, as a half WRITTEN BY HAND holds it: the objects
/// Foundation's JSON reader makes — NSDictionary / NSArray / NSNull with NSNumber and String — plus
/// `Data` for bytes. What its call's arguments are read INTO; what it answers with is written by
/// WireOut.json. (A generated half reads and writes its contract's structs directly: Wire.swift.)
public enum WireValue {
    /// Read a value the runtime handed over; valid only inside the call, so everything is copied.
    /// A top-level null is nil, a null inside is NSNull.
    public static func read(_ wire: WireIn) -> Any? {
        guard let v = wire.ref, lc_valueKind(v) != WireKind.null else { return nil }
        return object(v, bytes: true)
    }

    /// `bytes: false` = what JSON can say and nothing else: bytes read as a null.
    static func object(_ v: OpaquePointer, bytes: Bool) -> Any {
        switch lc_valueKind(v) {
        case WireKind.bool: return NSNumber(value: lc_valueBool(v))
        case WireKind.int: return NSNumber(value: lc_valueInt(v))
        case WireKind.double:
            let d = lc_valueDouble(v)
            return d.isFinite ? NSNumber(value: d) : NSNull()   // JSON's rule, whichever way the value came
        case WireKind.string:
            var length = 0
            return WireIn.text(lc_valueString(v, &length), length)
        case WireKind.bytes:
            if !bytes { return NSNull() }
            var count = 0
            guard let p = lc_valueBytes(v, &count), count > 0 else { return Data() }
            return Data(bytes: p, count: count)
        case WireKind.array:
            let n = lc_valueCount(v)
            var out: [Any] = []
            out.reserveCapacity(n)
            for i in 0..<n { out.append(lc_valueAt(v, i).map { object($0, bytes: bytes) } ?? NSNull()) }
            return out
        case WireKind.object:
            let n = lc_valueCount(v)
            var out: [String: Any] = [:]
            out.reserveCapacity(n)
            for i in 0..<n {
                var length = 0
                let key = WireIn.text(lc_valueKeyAt(v, i, &length), length)
                out[key] = lc_valueAt(v, i).map { object($0, bytes: bytes) } ?? NSNull()
            }
            return out
        default: return NSNull()
        }
    }
}
