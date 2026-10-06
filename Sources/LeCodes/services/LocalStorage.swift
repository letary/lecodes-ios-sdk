// The SDK localStorage's documents (storage.d.ts): the RUNTIME owns the map, its lazy load and
// the debounced whole-map save; the host only loads and saves one JSON document per storage name —
// Application Support/lecodes/storage/<name>.json. Loads are synchronous on the JS thread (a few
// KB); saves go to a background queue, atomically.
import Foundation

final class LocalStorage {
    private let queue = DispatchQueue(label: "codes.le.lecodes.storage", qos: .utility)

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("lecodes", isDirectory: true).appendingPathComponent("storage", isDirectory: true)
    }

    private func url(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent("\(safe).json", isDirectory: false)
    }

    func load(_ name: String) -> String? {
        // A save may be in flight: let it land first so a reload sees the newest document.
        queue.sync {}
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ name: String, _ json: String) {
        let target = url(for: name)
        queue.async {
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try json.data(using: .utf8)?.write(to: target, options: .atomic)
            } catch {
                print("[storage] save \(name): \(error.localizedDescription)")
            }
        }
    }
}
