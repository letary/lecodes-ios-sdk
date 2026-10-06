// The service channel (docs/service-channel-plan.md): the UI-less sibling of the NativeView
// channel. The host registers named factories (`engine.registerService("geolocation") { params,
// channel in … }`); the SDK talks to them over call / event sessions of values (service.d.ts). Sessions
// open cheaply (no permission prompt, no I/O) — prompts belong in the first call that needs them.
// Session ids are host-allocated from 1 and never reused. The `onEvent` handle of a session is
// BORROWED: delivered through Core.callBorrowed, freed exactly once when the session dies.
import Foundation
import LeCodesCore

/// The event channel handed to a service factory — `emit` delivers a service event to the
/// session's SDK-side listeners. Any thread; the payload is data (ChannelSettle.resolve says what) or nil.
public struct ServiceChannel {
    private let sessionId: Int32
    private weak var registry: Services?

    init(sessionId: Int32, registry: Services) {
        self.sessionId = sessionId
        self.registry = registry
    }

    public func emit(_ event: String, _ payload: Any? = nil) {
        registry?.emitEvent(sessionId, event) { out in if let payload { out.json(payload) } }
    }
    /// The same with the payload WRITTEN (the generated events of a contract); nothing written =
    /// no payload.
    public func emit(_ event: String, writing write: (WireOut) -> Void) { registry?.emitEvent(sessionId, event, write) }
}

/// One live service session. `call` settles asynchronously (exactly once); `close` stops whatever
/// the session started (a GPS watch) — on the SDK's close AND on the world's teardown.
public protocol ServiceInstance: AnyObject {
    func call(_ method: String, _ args: [Any], _ settle: ChannelSettle)
    func close()
}

public extension ServiceInstance {
    func close() {}
}

/// A session that reads its arguments off the wire itself (the GENERATED glue of a contract): the
/// host hands it the runtime's value, no Foundation objects are made of it.
public protocol WireServiceInstance: ServiceInstance {
    func call(_ method: String, wire args: WireIn, _ settle: ChannelSettle)
}

public extension WireServiceInstance {
    /// The way of a half written by hand, for a caller that holds Foundation's objects.
    func call(_ method: String, _ args: [Any], _ settle: ChannelSettle) {
        WireIn.of(args) { call(method, wire: $0, settle) }
    }
}

public typealias ServiceFactory = (_ params: Any?, _ channel: ServiceChannel) -> ServiceInstance

final class Services {
    private var factories: [String: ServiceFactory] = [:]
    private var versions: [String: Int32] = [:]

    private struct Session {
        var instance: ServiceInstance?   // nil while the factory runs (it may emit already)
        var wired: WireServiceInstance?  // the same instance, when it reads the wire itself
        let onEvent: JSCallback
    }
    private var sessions: [Int32: Session] = [:]
    private var nextSessionId: Int32 = 1
    private let lock = NSLock()

    /// `version` = the contract version the half was generated from (1 for one written by hand).
    func register(_ name: String, version: Int32 = 1, _ factory: @escaping ServiceFactory) {
        if factories[name] != nil {
            print("LeCodes: registerService(\"\(name)\") replaces an existing registration — plugin name collision? Last one wins.")
        }
        factories[name] = factory
        versions[name] = version
    }

    func isSupported(_ name: String) -> Bool { factories[name] != nil }
    /// HostService.version: 0 = no such service.
    func version(_ name: String) -> Int32 { versions[name] ?? 0 }

    /// Open a session: the id, or -1 when no factory is registered under `name` (the handle is then
    /// the runtime's to free — never taken here).
    func open(_ name: String, _ paramsJson: String, _ onEvent: JSCallback) -> Int32 {
        guard let factory = factories[name] else { return -1 }
        lock.lock()
        let id = nextSessionId
        nextSessionId += 1
        sessions[id] = Session(instance: nil, wired: nil, onEvent: onEvent)   // the channel works inside the factory
        lock.unlock()
        let instance = factory(ChannelValues.params(paramsJson), ServiceChannel(sessionId: id, registry: self))
        lock.lock()
        sessions[id]?.instance = instance
        sessions[id]?.wired = instance as? WireServiceInstance
        lock.unlock()
        return id
    }

    /// `args` is valid for this call only: a half reads what it keeps before it returns.
    func call(_ sessionId: Int32, _ method: String, _ args: WireIn, _ onComplete: JSCallback, _ onError: JSCallback) {
        let settle = ChannelSettle(onComplete, onError)
        lock.lock(); let session = sessions[sessionId]; lock.unlock()
        guard let instance = session?.instance else { settle.reject("Service call on a closed session"); return }
        if let wired = session?.wired { wired.call(method, wire: args, settle) }
        else { instance.call(method, ChannelValues.args(args), settle) }
    }

    /// The SDK's close or the runtime's world teardown: stop the provider, free the handle.
    func close(_ sessionId: Int32) {
        lock.lock(); let session = sessions.removeValue(forKey: sessionId); lock.unlock()
        guard let session else { return }
        session.instance?.close()
        Core.free(session.onEvent)
    }

    /// Deliver a service event to the session's SDK listeners (any thread).
    func emitEvent(_ sessionId: Int32, _ event: String, _ write: (WireOut) -> Void) {
        lock.lock(); let onEvent = sessions[sessionId]?.onEvent; lock.unlock()
        guard let onEvent else { return }
        Core.emitBorrowed(onEvent, event: event, writing: write)
    }
}
