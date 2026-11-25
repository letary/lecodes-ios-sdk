// `secureStorage` on iOS (storage.d.ts, the HostStorage secure slots): one Keychain generic password
// per (storage name, key) — service "lecodes.secureStorage:<name>", account = the key — readable after
// the device's first unlock, on this device only (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: in
// no backup, not in iCloud Keychain; background code reads it while the screen is locked).
//
// The Keychain OUTLIVES the app: a reinstall would find the last install's secrets. So the first op of
// an install — UserDefaults (which the uninstall did delete) lacks the flag — deletes every item of
// ours first, then sets the flag. Ops run in call order on one serial queue, off the JS thread; the
// answer is the caller's to deliver.
import Foundation
import Security

final class SecureStorage {
    static let servicePrefix = "lecodes.secureStorage:"
    static let installedFlag = "lecodes.secureStorage.installed"

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? ""
            return "keychain \(status)\(text.isEmpty ? "" : ": " + text)"
        }
    }

    private let queue = DispatchQueue(label: "codes.le.lecodes.secure-storage", qos: .userInitiated)
    private let defaults: UserDefaults
    private var installChecked = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: - async, in order (the host slots)

    func get(_ name: String, _ key: String, _ done: @escaping (Result<String?, Error>) -> Void) {
        queue.async { done(Result<String?, Error> { try self.ensureInstall(); return try self.read(name, key) }) }
    }
    func set(_ name: String, _ key: String, _ value: String, _ done: @escaping (Result<Void, Error>) -> Void) {
        queue.async { done(Result<Void, Error> { try self.ensureInstall(); try self.write(name, key, value) }) }
    }
    func remove(_ name: String, _ key: String, _ done: @escaping (Result<Void, Error>) -> Void) {
        queue.async { done(Result<Void, Error> { try self.ensureInstall(); try self.delete(name, key) }) }
    }

    // MARK: - the Keychain (synchronous: the queue's, and the tests')

    func read(_ name: String, _ key: String) throws -> String? {
        var query = item(name, key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = out as? Data, let text = String(data: data, encoding: .utf8) else {
            SecItemDelete(item(name, key) as CFDictionary)   // not ours to read: dropped, reads as empty
            return nil
        }
        return text
    }

    func write(_ name: String, _ key: String, _ value: String) throws {
        let attributes: [CFString: Any] = [
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(item(name, key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item(name, key).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(_ name: String, _ key: String) throws {
        let status = SecItemDelete(item(name, key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Delete every item of ours, whatever its storage name; another code's Keychain items stay.
    func deleteAll() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        for attributes in (out as? [[String: Any]]) ?? [] {
            guard let service = attributes[kSecAttrService as String] as? String, service.hasPrefix(Self.servicePrefix) else { continue }
            var one: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
            if let account = attributes[kSecAttrAccount as String] { one[kSecAttrAccount] = account }
            let deleted = SecItemDelete(one as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainError(status: deleted) }
        }
    }

    /// The first op of an install wipes what an earlier install left in the Keychain.
    func ensureInstall() throws {
        if installChecked { return }
        if !defaults.bool(forKey: Self.installedFlag) {
            try deleteAll()
            defaults.set(true, forKey: Self.installedFlag)
        }
        installChecked = true
    }

    private func item(_ name: String, _ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.servicePrefix + name, kSecAttrAccount: key]
    }
}
