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
// matches the binary's embedded bundle is discarded.
//
// What a download must be to replace the active bundle (the header lines every compiled bundle
// opens with): the SAME contract major as this runtime (`// sdk:` — the platform serves one by
// `?sdk=`, a custom url is one file, and the runtime would refuse another major on `run()`, which
// is a blank app re-downloading the same file every launch), and NOT OLDER than the bundle running
// now (`// last-updated:`, the compile time — a store build that ships newer code than the source
// still holds must not be downgraded by its first launch). A refused download is not activated;
// its ETag is kept so the next check still costs a 304.
//
// Swift + URLSession only: nothing of the engine. A `file://` source works (the dev loop, the tests).
import CryptoKit
import Foundation
import LeCodesCore   // Core.sdkVersion: the contract major a download must match

public enum LeCodesUpdater {

    /// The Info.plist key holding the update URL. Absent → every check is a no-op.
    public static let infoPlistKey = "LeCodesUpdateURL"

    public enum UpdateResult: Equatable {
        case unconfigured          // no source URL
        case upToDate              // 304, or the same content as the one already active
        case updated               // a new bundle stored — runs on the next launch
        case refused(String)       // the source serves a bundle this app must not run: another SDK major, or older than the active one
        case failed(String)        // a network / server problem — normal when offline
    }

    // MARK: - The bundle header (sdk/src/compile/header.ts)

    /// `// sdk: <version>` and `// last-updated: <ISO date>` of a compiled bundle's first lines.
    struct BundleHeader: Equatable {
        var sdk: String?
        var lastUpdated: String?
    }

    static func header(of data: Data) -> BundleHeader {
        let head = String(decoding: data.prefix(2000), as: UTF8.self)
        var h = BundleHeader()
        for line in head.split(separator: "\n", omittingEmptySubsequences: false).prefix(16) {
            if line.hasPrefix("// sdk: ") { h.sdk = String(line.dropFirst("// sdk: ".count)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("// last-updated: ") { h.lastUpdated = String(line.dropFirst("// last-updated: ".count)).trimmingCharacters(in: .whitespaces) }
            else if !line.hasPrefix("//") { break }   // the header is the leading comment block
        }
        return h
    }

    /// The major of "X.Y.Z"; nil when the string is not a version (a pre-2.0 bundle has no line).
    static func major(_ version: String?) -> Int? {
        guard let version, let dot = version.firstIndex(of: "."), let n = Int(version[..<dot]) else { return nil }
        return n
    }

    /// Why a downloaded bundle may not replace `active`; nil = it may. Both dates are
    /// `Date.toISOString()` strings, so lexical order is time order; a bundle without a date (an
    /// older compiler) is not held back by the rule.
    static func refusal(of download: Data, over active: Data, runtime: String = Core.sdkVersion) -> String? {
        let h = header(of: download)
        guard let m = major(h.sdk), m == major(runtime) else {
            return "the source serves a bundle of SDK \(h.sdk ?? "pre-2.0"), this app runs \(runtime)"
        }
        if let got = h.lastUpdated, let have = header(of: active).lastUpdated, got < have {
            return "the source's bundle (\(got)) is older than the active one (\(have))"
        }
        return nil
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

            // What runs now: the cached update when it is still this binary's, else the embedded bundle.
            let usable = state?.baseline == baseline && state?.url == source.absoluteString
            let cached: Data? = usable ? (try? Data(contentsOf: updateFile)).flatMap { sha256($0) == state!.hash ? $0 : nil } : nil
            let activeData = cached ?? embeddedData
            let active = usable ? state!.hash : baseline

            // The download replaces the active bundle only when it is one this app may run (the header
            // rules above); a refused one leaves the active bundle in place but keeps the new
            // validators, so the next launch's check is still a 304 instead of the same download.
            let why = refusal(of: data, over: activeData)
            let stored = why == nil ? data : activeData
            let hash = sha256(stored)
            let newState = State(
                url: source.absoluteString, baseline: baseline, hash: hash,
                etag: http?.value(forHTTPHeaderField: "ETag"),
                lastModified: http?.value(forHTTPHeaderField: "Last-Modified")
            )
            do {
                try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
                // Written even when identical to the embedded bundle: the state and the file must
                // stay a pair, or the next activeBundle() would clear the state and forget the ETag.
                try stored.write(to: updateFile, options: .atomic)
                try JSONEncoder().encode(newState).write(to: stateFile, options: .atomic)
                if let why { print("LeCodes: bundle update refused — \(why)"); onDone?(.refused(why)); return }
                if hash != active { print("LeCodes: bundle update stored (\(data.count) bytes) — active on the next launch") }
                onDone?(hash != active ? .updated : .upToDate)
            } catch {
                onDone?(.failed("store failed: \(error.localizedDescription)"))
            }
        }.resume()
    }
}
