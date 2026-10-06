// Native (JS-free) over-the-air updates of the bundle a shell runs — the 1.x updater, carried over.
//
// The app always launches from a LOCAL bundle — a previously downloaded update in Application
// Support, or the embedded app.js — so an offline launch never changes. `checkForUpdate` then asks
// the source URL for newer code with a conditional GET (unchanged code costs a ~0-byte 304); a fresh
// bundle is written atomically and runs on the NEXT launch. Call it BEFORE running the bundle: a
// broken JS update can crash the app all it wants, the next launch still fetches the fix (App Store
// §3.3.1B: interpreted code, downloaded by the app's own native code).
//
// The source: `LeCodesUpdateURL` of Info.plist (`lecodes app sync` writes it from app.json "update" —
// by default the project's bundle on the platform, `/code/<uuid>.js?sdk=<version>`, the launcher's
// own URL), or what the caller hands over. A store update always wins: each download records the
// hash of the embedded bundle it was fetched on top of, and a cached update whose baseline no longer
// matches the binary's embedded bundle is discarded. The runtime refuses a bundle of another
// contract major on `run()`, so a wrong-major download never runs.
//
// Swift + URLSession only: nothing of the engine. A `file://` source works (the dev loop, the tests).
import CryptoKit
import Foundation

public enum LeCodesUpdater {

    /// The Info.plist key holding the update URL. Absent → every check is a no-op.
    public static let infoPlistKey = "LeCodesUpdateURL"

    public enum UpdateResult: Equatable {
        case unconfigured          // no source URL
        case upToDate              // 304, or the same content as the one already active
        case updated               // a new bundle stored — runs on the next launch
        case failed(String)        // a network / server problem — normal when offline
    }

    private struct State: Codable {
        var url: String            // the source the cached update came from
        var baseline: String       // sha256 of the EMBEDDED bundle at download time
        var hash: String           // sha256 of the cached update.js
        var etag: String?
        var lastModified: String?
    }

    /// Test hook: where the update and its state live (default: Application Support/LeCodes).
    nonisolated(unsafe) public static var storageOverride: URL?

    private static var storageDir: URL {
        if let storageOverride { return storageOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LeCodes", isDirectory: true)
    }
    private static var updateFile: URL { storageDir.appendingPathComponent("update.js") }
    private static var stateFile: URL { storageDir.appendingPathComponent("update-state.json") }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private static func clearUpdate() {
        try? FileManager.default.removeItem(at: updateFile)
        try? FileManager.default.removeItem(at: stateFile)
    }

    /// The source Info.plist names (`LeCodesUpdateURL`); nil when the app has none.
    public static var configuredURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
              let url = URL(string: s), !s.isEmpty else { return nil }
        return url
    }

    /// The bundle the app carries (`App/Resources/app.js`, what `lecodes app sync` embeds).
    public static var embeddedBundleURL: URL? {
        Bundle.main.url(forResource: "app", withExtension: "js")
    }

    // MARK: - The launch path (local reads only)

    /// The bundle the app should run: the cached update when it is still valid for this binary
    /// (the same embedded baseline, the same source URL, an intact file), else the embedded
    /// bundle. Never touches the network. nil = no embedded bundle at all.
    public static func activeBundle(embeddedAt url: URL? = nil, source: URL? = nil) -> String? {
        guard let embeddedURL = url ?? embeddedBundleURL,
              let embeddedData = try? Data(contentsOf: embeddedURL),
              let embedded = String(data: embeddedData, encoding: .utf8) else { return nil }

        guard let state = loadState() else { return embedded }

        // A store update changed the embedded bundle → it supersedes any older download. A changed
        // source URL likewise invalidates what the old source delivered.
        if state.baseline != sha256(embeddedData) || state.url != (source ?? configuredURL)?.absoluteString {
            clearUpdate()
            return embedded
        }

        guard let cachedData = try? Data(contentsOf: updateFile),
              sha256(cachedData) == state.hash,                    // integrity: a partial / corrupt file
              let cached = String(data: cachedData, encoding: .utf8) else {
            clearUpdate()
            return embedded
        }
        return cached
    }

    // MARK: - The background check

    /// Ask the source for newer code (a conditional GET: ~0 bytes when unchanged). A new bundle is
    /// stored atomically and used on the NEXT launch. Failures are silent no-ops — offline is a
    /// normal state, the local bundle keeps running.
    public static func checkForUpdate(url: URL? = nil, embeddedAt: URL? = nil,
                                      onDone: (@Sendable (UpdateResult) -> Void)? = nil) {
        guard let source = url ?? configuredURL else { onDone?(.unconfigured); return }
        guard let embeddedURL = embeddedAt ?? embeddedBundleURL,
              let embeddedData = try? Data(contentsOf: embeddedURL) else {
            onDone?(.failed("no embedded bundle")); return
        }
        let baseline = sha256(embeddedData)

        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData   // our own conditional logic below
        let state = loadState()
        // Only revalidate against a cache that is actually usable for this binary + URL.
        if let state, state.url == source.absoluteString, state.baseline == baseline {
            if let etag = state.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lm = state.lastModified { request.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { onDone?(.failed(error.localizedDescription)); return }
            // A file:// source answers with no HTTP response: it is a 200.
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            if status == 304 { onDone?(.upToDate); return }
            guard status == 200, let data, !data.isEmpty else {
                onDone?(.failed("HTTP \(status)")); return
            }

            // Cheap sanity: a compiled bundle opens with its `// sdk:` header. Keeps a captive
            // portal's HTML page from becoming the next launch's "bundle".
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard data.starts(with: Array("//".utf8)) || contentType.contains("javascript") else {
                onDone?(.failed("not a JS bundle (\(contentType))")); return
            }

            let hash = sha256(data)
            let active = (state?.baseline == baseline && state?.url == source.absoluteString)
                ? state!.hash : baseline
            let newState = State(
                url: source.absoluteString, baseline: baseline, hash: hash,
                etag: http?.value(forHTTPHeaderField: "ETag"),
                lastModified: http?.value(forHTTPHeaderField: "Last-Modified")
            )
            do {
                try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
                // Written even when identical to the embedded bundle: the state and the file must
                // stay a pair, or the next activeBundle() would clear the state and forget the ETag.
                try data.write(to: updateFile, options: .atomic)
                try JSONEncoder().encode(newState).write(to: stateFile, options: .atomic)
                if hash != active { print("LeCodes: bundle update stored (\(data.count) bytes) — active on the next launch") }
                onDone?(hash != active ? .updated : .upToDate)
            } catch {
                onDone?(.failed("store failed: \(error.localizedDescription)"))
            }
        }.resume()
    }
}
