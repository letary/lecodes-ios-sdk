// The `storage` table (storage.d.ts): one JSON document per storage name, in Application Support.
import Foundation
import LeCodesCore

final class StorageHost: HostStorage {
    private let storage = LocalStorage()
    var load: ((String) -> String?)? { { [storage] name in storage.load(name) } }
    var save: ((String, String) -> Void)? { { [storage] name, json in storage.save(name, json) } }
}
