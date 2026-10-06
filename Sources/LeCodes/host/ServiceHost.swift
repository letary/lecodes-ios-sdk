// The `service` table (service.d.ts): the headless-service sessions of Services (registerService).
import Foundation
import LeCodesCore

final class ServiceHost: HostService {
    weak var engine: LeCodesEngine?
    private var services: Services? { engine?.services }

    func supported(name: String) -> Bool { services?.isSupported(name) ?? false }
    /// -1 hands the handle back to the runtime; otherwise Services owns it until close.
    func open(name: String, params: String, onEvent: JSCallback) -> Int32 { services?.open(name, params, onEvent) ?? -1 }
    var version: ((String) -> Int32)? { { [weak self] name in self?.services?.version(name) ?? 0 } }
    func call(serviceId: Int32, method: String, args: WireIn, onComplete: JSCallback, onError: JSCallback) {
        guard let services else { Core.reject(onComplete, reject: onError, message: "no services"); return }
        services.call(serviceId, method, args, onComplete, onError)
    }
    func close(serviceId: Int32) { services?.close(serviceId) }
}
