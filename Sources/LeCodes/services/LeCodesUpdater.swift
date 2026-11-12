// Native (JS-free) over-the-air updates of the bundle a shell runs — the 1.x updater, carried over.
//
// The app launches from a LOCAL bundle — a previously downloaded update in Application Support, or
// the embedded app.js — so an offline launch never changes. `checkForUpdate` asks the source URL
// for newer code with a conditional GET (unchanged code costs a ~0-byte 304); a fresh bundle is
// written atomically and is what the next `activeBundle()` returns. A shell (LeCodesShell.boot)
// reads the local bundle FIRST, then starts the check BEFORE anything runs: a broken JS update can
// crash the app all it wants, the next launch still fetches the fix (App Store §3.3.1B:
// interpreted code, downloaded by the app's own native code). On the first launch of a binary (no
// usable state — `hasUsableState`) the shell waits for that check, a few seconds at most, and runs
// what it stored; every later launch runs the local bundle at once and a download applies on the
// next one.
//
// The source: `LeCodesUpdateURL` of Info.plist (`lecodes app sync` writes it from app.json "update" —
// by default the project's bundle on the platform, `/code/<uuid>.js?sdk=<version>`, the launcher's
// own URL), or what the caller hands over. The state belongs to one binary and one source: each
// download records the hash of the embedded bundle it was fetched on top of (its baseline) and its
// URL. A store update changes the embedded bundle; the cached update then survives only when it is
// intact, one this runtime may run (the rules below, over the NEW embedded bundle) and STRICTLY
// newer than it by `// last-updated:` (equal or missing dates → the embedded bundle). A kept update
// is re-baselined onto the new binary with its validators, so the next check still costs a 304.
// Otherwise it is discarded — a store build compiled after the OTA push carries a newer date and
// wins, so a store release still fixes a broken OTA. A changed source URL discards it as well.
//
// The app may name another source for itself (`app.update.setSource(url)` of the SDK — a dev
// channel for the people who test a build first): `setSourceOverride` keeps the URL in a file of
// its own beside the state, outside the JS world, and `sourceURL` — what a shell boots with — is
// that URL, else the build's. Nothing else knows of it: the rules below are the same for every
// source, and the override is a changed source like any other — the cached update is dropped, so
// the next launch is a first one (it waits for the check) over the embedded bundle. It outlives
// store updates; `setSourceOverride(nil)` returns to the build's source.
//
// What a download must be to replace the active bundle (the header lines every compiled bundle
// opens with): the SAME contract major as this runtime (`// sdk:` — the platform serves one by
// `?sdk=`, a custom url is one file, and the runtime would refuse another major on `run()`, which
// is a blank app re-downloading the same file every launch), and NOT OLDER than the bundle running
// now (`// last-updated:`, the compile time — a store build that ships newer code than the source
// still holds must not be downgraded by its first launch). A refused download is not activated;
// its ETag is kept so the next check still costs a 304.
//
// The first launch of a binary has no validators to send, and `lecodes app sync` compiles the
// embedded bundle itself, so its bytes never equal the source's: that check would download the
// whole bundle just to apply the date rule to it. Instead it sends the embedded bundle's compile
// date as `If-Modified-Since`: a source whose bundle is not newer (the platform's serveFile, nginx,
// S3 — the file's mtime against the date) answers 304, the embedded bundle runs, and the 304's own
// validators are stored, so the next launch runs at once and revalidates by ETag. A newer source
// answers 200 and the download applies as above. The date rule after a download stays the authority:
// a file rewritten in place (a newer mtime, the same old code) costs one download and is refused.
//
// The dates cannot tell the same code apart: a developer syncs and builds the store app from a
// commit, then pushes it, and hub's environment serves its own build of that commit with the
// promote's date — later than the embedded bundle's, so every fresh install would download the
// code it already has. So every check also names the commit of the bundle that runs now (the
// `// commit:` line of what `activeBundle()` returns, as `LeCodes-Commit`; a bundle without the
// line, or with something that is no git object id, sends nothing). A source that serves that
// very commit answers 304 whatever the validators say (LeCodesHub docs/edge.md, "The shells"),
// and the 304 is handled as any other (`lecodes app sync` writes the line only for a bundle that
// IS that commit's build). A header, not a query parameter: a custom source may be a signed URL
// that one more parameter would break; a source that does not know it ignores it.
//
// Swift + URLSession only: nothing of the engine. A `file://` source works (the dev loop, the tests).
import CryptoKit
import Foundation
import LeCodesCore   // Core.sdkVersion: the contract major a download must match

public enum LeCodesUpdater {

    /// The Info.plist key holding the update URL. Absent → every check is a no-op.
    public static let infoPlistKey = "LeCodesUpdateURL"

    public enum UpdateResult: Equatable, Sendable {
        case unconfigured          // no source URL
        case upToDate              // 304, or the same content as the one already active
        case updated               // a new bundle stored — what the next activeBundle() returns
        case refused(String)       // the source serves a bundle this app must not run: another SDK major, or older than the active one
        case failed(String)        // a network / server problem — normal when offline
    }

    // MARK: - The bundle header (sdk/src/compile/header.ts)

    /// `// sdk: <version>`, `// last-updated: <ISO date>` and `// commit: <sha>` of a compiled
    /// bundle's first lines.
    struct BundleHeader: Equatable {
        var sdk: String?
        var lastUpdated: String?
        var commit: String?
    }

    static func header(of data: Data) -> BundleHeader {
        let head = String(decoding: data.prefix(2000), as: UTF8.self)
        var h = BundleHeader()
        for line in head.split(separator: "\n", omittingEmptySubsequences: false).prefix(16) {
            if line.hasPrefix("// sdk: ") { h.sdk = String(line.dropFirst("// sdk: ".count)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("// last-updated: ") { h.lastUpdated = String(line.dropFirst("// last-updated: ".count)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("// commit: ") { h.commit = String(line.dropFirst("// commit: ".count)).trimmingCharacters(in: .whitespaces) }
            else if !line.hasPrefix("//") { break }   // the header is the leading comment block
        }
        return h
    }

    /// The request header naming the commit of the bundle that runs now.
    static let commitHeader = "LeCodes-Commit"

    /// What a check sends as `LeCodes-Commit`: the bundle's `// commit:` line when it is a git
    /// object id (40–64 lowercase hex, sha1 or sha256), nil otherwise (no line: nothing is sent).
    static func commit(of bundle: Data) -> String? {
        guard let line = header(of: bundle).commit, (40...64).contains(line.utf8.count),
              line.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        return line
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

    /// Whether a cached update outlives a store update that changed the embedded bundle: one this
    /// runtime may run over the NEW embedded bundle (`refusal` nil — the same major, not older) and
    /// STRICTLY newer than it. An equal or a missing date keeps the store build's code.
    static func survives(_ cached: Data, over embedded: Data, runtime: String = Core.sdkVersion) -> Bool {
        guard refusal(of: cached, over: embedded, runtime: runtime) == nil,
              let got = header(of: cached).lastUpdated, let have = header(of: embedded).lastUpdated else { return false }
        return got > have
    }

    /// What the first launch of a binary sends in place of validators: the embedded bundle's
    /// `// last-updated:` as an HTTP-date (second precision, floored — the format has none better),
    /// nil without the line (an older compiler: the check downloads as before).
    static func ifModifiedSince(of embedded: Data) -> String? {
        guard let iso = header(of: embedded).lastUpdated, iso.count >= 19 else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = parser.date(from: String(iso.prefix(19))) else { return nil }
        let http = DateFormatter()
        http.locale = Locale(identifier: "en_US_POSIX")
        http.timeZone = TimeZone(identifier: "UTC")
        http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return http.string(from: date)
    }

    private struct State: Codable {
        var url: String            // the source the cached update came from
        var baseline: String       // sha256 of the EMBEDDED bundle at download time (or the one it was re-baselined onto)
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

    // MARK: - The source the app set for itself (app.update.setSource)

    /// Whether this process booted as a shell (LeCodesShell.boot sets it): only a shell's updater
    /// reads the override, so only a shell answers `app.update` (host/AppHost).
    nonisolated(unsafe) public static var isShell = false

    private static var sourceFile: URL { storageDir.appendingPathComponent("update-source.txt") }

    /// The source the app set with `setSourceOverride`; nil while it updates from the build's.
    public static var sourceOverride: URL? {
        guard let text = try? String(contentsOf: sourceFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    /// Make `url` the source every later launch updates from; nil returns to the build's. False
    /// when it is not a URL (no scheme) or could not be stored — nothing changed.
    @discardableResult
    public static func setSourceOverride(_ url: URL?) -> Bool {
        guard let url else {
            try? FileManager.default.removeItem(at: sourceFile)
            return !FileManager.default.fileExists(atPath: sourceFile.path)
        }
        guard url.scheme != nil else { return false }   // a string no check could ever fetch
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            try Data(url.absoluteString.utf8).write(to: sourceFile, options: .atomic)
            return true
        } catch { return false }
    }

    /// Where this app updates from: the source it set for itself, else the build's.
    public static var sourceURL: URL? { sourceOverride ?? configuredURL }

    /// The bundle the app carries (`App/Resources/app.js`, what `lecodes app sync` embeds).
    public static var embeddedBundleURL: URL? {
        Bundle.main.url(forResource: "app", withExtension: "js")
    }

    // MARK: - The launch path (local reads only)

    /// The bundle the app should run: the cached update when it is still valid for this binary
    /// (the same source URL, an intact file, the same embedded baseline — or, after a store
    /// update, newer code than the new embedded bundle, which it is then re-baselined onto), else
    /// the embedded bundle. Never touches the network. nil = no embedded bundle at all.
    public static func activeBundle(embeddedAt url: URL? = nil, source: URL? = nil) -> String? {
        activeBundle(embeddedAt: url, source: source, runtime: Core.sdkVersion)
    }

    static func activeBundle(embeddedAt url: URL?, source: URL?, runtime: String) -> String? {
        guard let embeddedURL = url ?? embeddedBundleURL,
              let embeddedData = try? Data(contentsOf: embeddedURL),
              let embedded = String(data: embeddedData, encoding: .utf8) else { return nil }

        guard var state = loadState() else { return embedded }

        // A changed source URL invalidates what the old source delivered.
        guard state.url == (source ?? sourceURL)?.absoluteString,
              let cachedData = try? Data(contentsOf: updateFile),
              sha256(cachedData) == state.hash,                    // integrity: a partial / corrupt file
              let cached = String(data: cachedData, encoding: .utf8) else {
            clearUpdate()
            return embedded
        }

        // A store update changed the embedded bundle: the download outlives it only as newer code
        // this runtime may run, re-baselined onto the new binary (the validators kept: the next
        // check is still a 304). Else the store build wins.
        let baseline = sha256(embeddedData)
        if state.baseline != baseline {
            guard survives(cachedData, over: embeddedData, runtime: runtime) else {
                clearUpdate()
                return embedded
            }
            state.baseline = baseline
            try? JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
            print("LeCodes: the cached update (\(header(of: cachedData).lastUpdated ?? "")) is newer than the new embedded bundle — kept")
        }
        return cached
    }

    /// Whether the update state belongs to THIS binary and source: the cached update was fetched on
    /// top of this embedded bundle (or re-baselined onto it by `activeBundle`) from this URL. A
    /// check revalidates only against such a state (it sends the validators), and a shell's boot
    /// reads its absence as the first launch of this binary. Read it AFTER `activeBundle()`, which
    /// migrates or clears the state a store update left. False with no source or no embedded bundle.
    public static func hasUsableState(embeddedAt url: URL? = nil, source: URL? = nil) -> Bool {
        guard let source = source ?? sourceURL,
              let embeddedURL = url ?? embeddedBundleURL,
              let embeddedData = try? Data(contentsOf: embeddedURL) else { return false }
        return isUsable(loadState(), baseline: sha256(embeddedData), source: source)
    }

    /// THE notion of a usable state (hasUsableState, checkForUpdate): this baseline, this source.
    private static func isUsable(_ state: State?, baseline: String, source: URL) -> Bool {
        guard let state else { return false }
        return state.baseline == baseline && state.url == source.absoluteString
    }

    // MARK: - The background check

    /// Ask the source for newer code (a conditional GET: ~0 bytes when unchanged). A new bundle is
    /// stored atomically: the next `activeBundle()` returns it (a shell's first launch runs it at
    /// once, every later launch on the next one). Failures are silent no-ops — offline is a normal
    /// state, the local bundle keeps running. `onDone` is called on a background queue.
    public static func checkForUpdate(url: URL? = nil, embeddedAt: URL? = nil,
                                      onDone: (@Sendable (UpdateResult) -> Void)? = nil) {
        guard let source = url ?? sourceURL else { onDone?(.unconfigured); return }
        guard let embeddedURL = embeddedAt ?? embeddedBundleURL,
              let embeddedData = try? Data(contentsOf: embeddedURL) else {
            onDone?(.failed("no embedded bundle")); return
        }
        let baseline = sha256(embeddedData)

        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData   // our own conditional logic below
        let state = loadState()
        // Only revalidate against a cache that is actually usable for this binary + URL; without one
        // (the first launch of this binary) the embedded bundle's compile date stands in: a source
        // that is not newer answers 304 instead of a bundle the date rule would refuse anyway.
        let usable = isUsable(state, baseline: baseline, source: source)
        if usable, let state {
            if let etag = state.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lm = state.lastModified { request.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        } else if let since = ifModifiedSince(of: embeddedData) {
            request.setValue(since, forHTTPHeaderField: "If-Modified-Since")
        }

        // What runs now: the cached update when it is still this binary's, else the embedded bundle.
        let cached: Data? = usable ? (try? Data(contentsOf: updateFile)).flatMap { sha256($0) == state!.hash ? $0 : nil } : nil
        let activeData = cached ?? embeddedData
        let active = usable ? state!.hash : baseline
        // ...and its commit, beside the validators: a source serving that commit answers 304.
        if let sha = commit(of: activeData) { request.setValue(sha, forHTTPHeaderField: commitHeader) }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { onDone?(.failed(error.localizedDescription)); return }
            // A file:// source answers with no HTTP response: it is a 200.
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            if status == 304 {
                // The source is not newer than the embedded bundle (the date stood in for a state),
                // or serves its commit: record it as this binary's state, with the 304's validators,
                // so the next launch runs at once and revalidates by ETag. The pair rule holds: the
                // file is the embedded bundle itself.
                if !usable {
                    let newState = State(
                        url: source.absoluteString, baseline: baseline, hash: baseline,
                        etag: http?.value(forHTTPHeaderField: "ETag"),
                        lastModified: http?.value(forHTTPHeaderField: "Last-Modified")
                    )
                    do {
                        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
                        try embeddedData.write(to: updateFile, options: .atomic)
                        try JSONEncoder().encode(newState).write(to: stateFile, options: .atomic)
                    } catch { onDone?(.failed("store failed: \(error.localizedDescription)")); return }
                }
                onDone?(.upToDate); return
            }
            guard status == 200, let data, !data.isEmpty else {
                onDone?(.failed("HTTP \(status)")); return
            }

            // Cheap sanity: a compiled bundle opens with its `// sdk:` header. Keeps a captive
            // portal's HTML page from becoming the next launch's "bundle".
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard data.starts(with: Array("//".utf8)) || contentType.contains("javascript") else {
                onDone?(.failed("not a JS bundle (\(contentType))")); return
            }

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
                if hash != active { print("LeCodes: bundle update stored (\(data.count) bytes)") }
                onDone?(hash != active ? .updated : .upToDate)
            } catch {
                onDone?(.failed("store failed: \(error.localizedDescription)"))
            }
        }.resume()
    }
}
