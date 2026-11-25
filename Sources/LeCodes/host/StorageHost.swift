// The `storage` table (storage.d.ts): one JSON document per storage name, in Application Support —
// and the secure slots over the Keychain (services/SecureStorage.swift). Those run on its queue and
// settle from there.
import Foundation
import LeCodesCore

final class StorageHost: HostStorage {
    private let storage = LocalStorage()
    private let secure = SecureStorage()
    var load: ((String) -> String?)? { { [storage] name in storage.load(name) } }
    var save: ((String, String) -> Void)? { { [storage] name, json in storage.save(name, json) } }

    var secureGet: ((String, String, JSCallback, JSCallback) -> Void)? {
        { [secure] name, key, onComplete, onReject in
            secure.get(name, key) { result in
                StorageHost.settle(onComplete, onReject, result.map { value in [value.map(LeValue.string) ?? .null] })
            }
        }
    }
    var secureSet: ((String, String, String, JSCallback, JSCallback) -> Void)? {
        { [secure] name, key, value, onComplete, onReject in
            secure.set(name, key, value) { result in StorageHost.settle(onComplete, onReject, result.map { _ in [] }) }
        }
    }
    var secureRemove: ((String, String, JSCallback, JSCallback) -> Void)? {
        { [secure] name, key, onComplete, onReject in
            secure.remove(name, key) { result in StorageHost.settle(onComplete, onReject, result.map { _ in [] }) }
        }
    }

    /// From the store's queue: Core.resolve / reject are thread-safe (the dispatch queue runs the call on
    /// the JS thread).
    private static func settle(_ onComplete: JSCallback, _ onReject: JSCallback, _ result: Result<[LeValue], Error>) {
        switch result {
        case .success(let args): Core.resolve(onComplete, reject: onReject, args)
        case .failure(let error): Core.reject(onComplete, reject: onReject, message: "secureStorage: \(error)")
        }
    }
}
