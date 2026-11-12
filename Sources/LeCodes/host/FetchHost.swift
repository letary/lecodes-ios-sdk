// The `fetch` table (fetch.d.ts): HTTP over URLSession (through CachedHTTP — the device cache's
// modes and the time limit are carried out there), the buffer store the response bodies land
// in (Buffers — every `systemId` the SDK holds is an entry there), the local assets by name (the
// app's hook, the SDK's own resource bundle, the files root — cached per name, dropped on write /
// remove) and the two system buffers (the IBL, the uberarchive).
import Foundation
import LeCodesCore

final class FetchHost: HostFetch {
    weak var engine: LeCodesEngine?

    /// `LeCodes/<sdk> (iOS; <os>)` — Android's shape (okhttp.kt): the SDK/runtime version this host
    /// embeds, whose major is the bundle ↔ runtime contract (the same number the launcher sends as
    /// `?sdk=`), never the app's store version.
    private static let userAgent: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let v = os.patchVersion > 0 ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)" : "\(os.majorVersion).\(os.minorVersion)"
        return "LeCodes/\(Core.sdkVersion) (iOS; \(v))"
    }()

    // MARK: - local assets

    /// path → the buffer id (the asset table; pinned in the store, never evicted).
    private var localIds: [String: Int32] = [:]

    func local(path: String) -> Int32 {
        if let id = localIds[path], Buffers.get(id) != nil { return id }
        let data = engine?.onFetchLocal(path)
            ?? LeCodesResources.localAsset(path)
            ?? filesRootData(path)
        guard let data else { return -1 }
        let id = Buffers.add(data, pin: true)
        localIds[path] = id
        return id
    }

    /// A file the app wrote (files.d.ts: `write(name)` and `local(name)` are a pair).
    private func filesRootData(_ path: String) -> Data? {
        guard let files = engine?.localFiles, !path.hasPrefix("/") else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: files.resolve(path)))
    }

    /// The file at `path` is about to change (files write / remove): the next `local` re-reads it.
    /// Only the shortcut goes — the bytes stay under the old id for whoever holds it.
    func dropLocalCache(_ path: String, withChildren: Bool = false) {
        localIds[path] = nil
        if withChildren {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            localIds = localIds.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    // The runtime released a fetched body: drop it (a local-asset id is pinned and stays).
    var dispose: ((Int32) -> Void)? { { id in Buffers.remove(id) } }
    // Canvas.toFile: the runtime encoded the surface itself and stores the bytes here.
    var putBuffer: ((UnsafeBufferPointer<UInt8>) -> Int32)? { { bytes in Buffers.add(Data(buffer: bytes)) } }

    func buffer(id: Int32, addByte: Bool) -> [UInt8]? { Buffers.get(id).map { [UInt8]($0) } }
    func bufferSlice(id: Int32, start: Int32, end: Int32, addByte: Bool) -> [UInt8]? {
        guard let data = Buffers.get(id) else { return nil }
        let from = max(0, min(Int(start), data.count))
        let to = max(from, min(Int(end), data.count))
        return [UInt8](data[from..<to])
    }
    func systemBuffer(id: Int32) -> [UInt8]? { LeCodesResources.systemBuffer(id).map { [UInt8]($0) } }

    // MARK: - request

    // `cache` / `timeoutMs` (the device cache's mode and the request's time limit, docs/cache.md) are
    // CachedHTTP's to carry out; a copy settles as status 200 with the third value (`cached`) true.
    func request(url: String, method: String, headers: [String], body: String?, form: [FetchFormEntry],
                 cache: String, timeoutMs: Int32, onComplete: JSCallback, onReject: JSCallback, onProgress: JSCallback) {
        let progress: JSCallback? = onProgress != 0 ? onProgress : nil
        // `id:<n>`: an asset the store already holds — resolve to it with status 200.
        if url.hasPrefix("id:") {
            if let id = Int32(url.dropFirst(3)), Buffers.get(id) != nil { Core.resolve(onComplete, reject: onReject, [.int(id), .int(200)]) }
            else { Core.reject(onComplete, reject: onReject, message: "asset not found: \(url)") }
            if let progress { Core.free(progress) }
            return
        }
        guard let requestURL = URL(string: url) else {
            Core.reject(onComplete, reject: onReject, message: "Invalid URL: \(url)")
            if let progress { Core.free(progress) }
            return
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method.isEmpty ? "GET" : method
        var i = 0
        while i + 1 < headers.count { request.setValue(headers[i + 1], forHTTPHeaderField: headers[i]); i += 2 }
        if request.value(forHTTPHeaderField: "User-Agent") == nil { request.setValue(FetchHost.userAgent, forHTTPHeaderField: "User-Agent") }
        if !form.isEmpty {
            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            do { request.httpBody = try FetchHost.multipart(form, boundary: boundary) }
            catch {
                Core.reject(onComplete, reject: onReject, message: "Invalid FormData: \(error)")
                if let progress { Core.free(progress) }
                return
            }
        } else if let body {
            request.httpBody = Data(body.utf8)
        }

        let settle = Settle(url: url, onComplete: onComplete, onReject: onReject, onProgress: progress)
        CachedHTTP.request(request, url: url, cache: cache, timeoutMs: timeoutMs,
                           onProgress: progress != nil ? { loaded, total in settle.progress(loaded: loaded, total: total) } : nil) { result in
            switch result {
            case .success(let answer): settle.resolve(answer.data, status: answer.status, cached: answer.cached)
            case .failure(let none): settle.reject(none.message)
            }
        }
    }

    /// One settle per request: exactly one of the pair, the progress handle freed with it.
    final class Settle {
        let url: String
        private let onComplete: JSCallback
        private let onReject: JSCallback
        let onProgress: JSCallback?
        private var done = false
        private let lock = NSLock()
        init(url: String, onComplete: JSCallback, onReject: JSCallback, onProgress: JSCallback?) {
            self.url = url; self.onComplete = onComplete; self.onReject = onReject; self.onProgress = onProgress
        }
        private func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        func resolve(_ data: Data, status: Int, cached: Bool) {
            guard take() else { return }
            Core.resolve(onComplete, reject: onReject, [.int(Buffers.add(data)), .int(Int32(status)), .bool(cached)])
            if let onProgress { Core.free(onProgress) }
        }
        func reject(_ message: String) {
            guard take() else { return }
            // Name the URL: URLSession's own text says nothing about WHICH request failed.
            Core.reject(onComplete, reject: onReject, message: "\(message): \(url)")
            if let onProgress { Core.free(onProgress) }
        }
        /// Nothing after the settle: the handle is freed with it, and a request the time limit ended
        /// may still hear of bytes on their way.
        func progress(loaded: Int, total: Int?) {
            guard let onProgress else { return }
            lock.lock(); defer { lock.unlock() }
            if done { return }
            var arg: [(String, LeValue)] = [("loaded", .int(Int32(clamping: loaded)))]
            if let total { arg.append(("total", .int(Int32(clamping: total)))) }
            Core.callBorrowed(onProgress, [.object(arg)])
        }
    }

    private static func multipart(_ form: [FetchFormEntry], boundary: String) throws -> Data {
        struct MissingBuffer: Error {}
        var body = Data()
        func line(_ s: String) { body.append(Data(s.utf8)) }
        for entry in form {
            line("--\(boundary)\r\n")
            if let value = entry.value {
                line("Content-Disposition: form-data; name=\"\(entry.key)\"\r\n\r\n")
                line(value)
            } else {
                guard let bytes = Buffers.get(entry.bufferId) else { throw MissingBuffer() }
                line("Content-Disposition: form-data; name=\"\(entry.key)\"; filename=\"\(entry.filename ?? "blob")\"\r\n")
                line("Content-Type: application/octet-stream\r\n\r\n")
                body.append(bytes)
            }
            line("\r\n")
        }
        line("--\(boundary)--\r\n")
        return body
    }
}
