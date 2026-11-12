// The files a build carries, by the ADDRESS a bundle names them with (docs/cache.md, "The embedded
// copies") — the twin of hosts/android's EmbeddedAssets.kt. A shell embeds the project's assets for
// the bundle compiled into it, which reads them by name; a bundle that arrives over the air names the
// same files by url. `lecodes app sync` writes the index that joins the two
// (`lecodes-embedded.json`, beside app.js):
//
//   { "files":     { "<key>": "<embedded name>" },   a key = a whole url (a registry font), or the
//                                                    file's content name `<sha256>[.<ext>]` — the
//                                                    last segment of an asset's url, whatever its host
//     "immutable": [ "<url prefix>" ] }              where a url never changes its content
//
// CachedHTTP.request — the one function this host's HTTP goes through — asks here first: a url the
// build carries is answered from the package, with no request; a url under an immutable prefix that
// the build does NOT carry (an asset a later bundle added) is fetched once and kept.
//
// Without an index (an app that is not a synced shell, an older CLI) nothing here answers.
import Foundation

enum EmbeddedAssets {
    /// The index's name among the embedded files.
    static let indexName = "lecodes-embedded.json"

    struct Index {
        var files: [String: String] = [:]
        var immutable: [String] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var index = Index()
    nonisolated(unsafe) private static var reader: (String) -> Data? = { _ in nil }

    /// `read` is the embedder's local resolver (LeCodesEngine.onFetchLocal); the index is read
    /// through it, here. Called by LeCodesShell.boot before the bundle runs.
    static func attach(_ read: @escaping (String) -> Data?) {
        attach(index: read(indexName), read)
    }

    /// The index as given (the tests), the files from `read`.
    static func attach(index data: Data?, _ read: @escaping (String) -> Data?) {
        let parsed = parse(data)
        lock.lock()
        reader = read
        index = parsed
        lock.unlock()
    }

    /// The embedded name of `url`'s file, or nil: the build does not carry it.
    static func name(of url: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if index.files.isEmpty { return nil }
        return index.files[url] ?? index.files[contentName(url)]
    }

    /// The embedded file's bytes; nil when it cannot be read (the request is then made).
    static func read(_ name: String) -> Data? {
        lock.lock()
        let read = reader
        lock.unlock()
        return read(name)
    }

    /// A url whose content never changes: what was fetched once is the file.
    static func isImmutable(_ url: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return index.immutable.contains { url.hasPrefix($0) }
    }

    /// The last segment of a url's path.
    static func contentName(_ url: String) -> String {
        var path = Substring(url)
        if let hash = path.firstIndex(of: "#") { path = path[..<hash] }
        if let query = path.firstIndex(of: "?") { path = path[..<query] }
        if let slash = path.lastIndex(of: "/") { path = path[path.index(after: slash)...] }
        return String(path)
    }

    static func parse(_ data: Data?) -> Index {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Index() }
        return Index(files: json["files"] as? [String: String] ?? [:], immutable: json["immutable"] as? [String] ?? [])
    }
}
