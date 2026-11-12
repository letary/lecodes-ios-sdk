// The device cache's modes, carried out (docs/cache.md "In a host") — the ONE function of this host
// that makes its HTTP: the `fetch` table (FetchHost.request) and the renderer's loads (the image
// loader and the fonts, HostRendererServices) both go through `request`. The twin of the desktop's
// httpRequestCached (hosts/desktop/src/host/io.cpp); the copies live in the runtime's store
// (creator-pkg/cache.h, here through Core.cacheRead / cacheWrite).
//
//   "force-cache"  the copy when there is one, without a request; else the network, a 200 is kept
//   "fallback"     the network, a 200 is kept; NO answer (no connection, the time limit) → the copy
//   "no-store"     the network only
//   none           URLSession.shared as it always was (URLCache and its HTTP rules included)
//
// Before any of it, a GET of a file the build itself carries (EmbeddedAssets) is answered from the
// package, as a copy; and a url that never changes its content is "force-cache" when no mode is named.
//
// A mode applies to a GET only. A request that names one never goes through URLCache: its copy is
// the store's, kept under the url alone, and HTTP's own freshness rules must not answer for it.
// "No answer" is honest: an HTTP error status IS an answer (it is handed over, never replaced by the
// copy), a body that broke off is none.
//
// Threads: `request` is called where the request starts (the JS thread: the live world's area is
// taken there); the store's files are read and written on `disk`, never on that thread; the
// completion comes on a background thread, never inside the call.
import Foundation
import LeCodesCore

enum CachedHTTP {
    struct Answer {
        let data: Data
        /// The HTTP status (0 for a url that is not HTTP); 200 for the copy.
        let status: Int
        /// The body is the kept copy.
        let cached: Bool
    }
    struct NoAnswer: Error {
        let message: String
    }

    /// A request under way. After `cancel` its completion is not called.
    final class Call {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var claimed = false
        private var cancelled = false

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }

        fileprivate func start(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let cancelled = self.cancelled
            lock.unlock()
            task.resume()
            if cancelled { task.cancel() }   // cancelled while its copy was looked up: the task still has to end
        }
        /// The network's answer and the time limit race for the request: the first one has it.
        fileprivate func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
        fileprivate func stop() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    /// Where the store's files are read and written.
    private static let disk = DispatchQueue(label: "lecodes.cache", qos: .utility, attributes: .concurrent)

    /// The session of a request that names a mode: no URLCache under it.
    private static let direct: URLSession = URLSession(configuration: directConfiguration())
    private static func directConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// `request` in the mode `cache` names (the SDK's spelling; "" = none). `url` is the address as
    /// the app wrote it — the copy's key. `timeoutMs` (0 = none) limits the WHOLE request: past it
    /// the request counts as not answered. `onProgress(loaded, total)` reports a body as it arrives.
    @discardableResult
    static func request(_ request: URLRequest, url: String, cache: String, timeoutMs: Int32 = 0,
                        priority: Float = URLSessionTask.defaultPriority,
                        onProgress: ((Int, Int?) -> Void)? = nil,
                        completion: @escaping (Result<Answer, NoAnswer>) -> Void) -> Call {
        let get = (request.httpMethod ?? "GET").uppercased() == "GET"
        // A file the build carries is read from the package (EmbeddedAssets); one it does not, at an
        // address that never changes its content, is fetched once and kept.
        let embedded = get ? EmbeddedAssets.name(of: url) : nil
        let named: Core.CacheMode = get ? Core.CacheMode(cache) : .none
        let mode: Core.CacheMode = get && named == .none && embedded == nil && EmbeddedAssets.isImmutable(url) ? .forceCache : named
        let area = Core.cacheArea()   // here, where the request starts: its answer may land after a world swap
        let call = Call()

        let finish: (Result<Answer, NoAnswer>) -> Void = { result in
            if !call.isCancelled { completion(result) }
        }
        let noAnswer: (String) -> Void = { message in
            guard mode == .fallback else { finish(.failure(NoAnswer(message: message))); return }
            disk.async {
                if let copy = Core.cacheRead(area: area, url: url) { finish(.success(Answer(data: copy, status: 200, cached: true))) }
                else { finish(.failure(NoAnswer(message: message))) }
            }
        }
        let landed: (Data?, Int, Error?) -> Void = { data, status, error in
            guard call.claim() else { return }   // the time ran out first
            guard let data, error == nil else { noAnswer(error?.localizedDescription ?? "Unknown error"); return }
            let answer = Answer(data: data, status: status, cached: false)
            guard mode.keeps, status == 200 else { finish(.success(answer)); return }
            // Kept BEFORE the answer is handed over: the next request of this url may need the copy.
            disk.async {
                Core.cacheWrite(area: area, url: url, data)
                finish(.success(answer))
            }
        }
        let network = {
            if call.isCancelled { return }
            var request = request
            if mode != .none { request.cachePolicy = .reloadIgnoringLocalCacheData }
            let task: URLSessionTask
            var ownSession: URLSession?
            if let onProgress {
                // The streaming path: a delegate reports progress; the session invalidates itself after.
                let configuration = mode == .none ? URLSessionConfiguration.default : directConfiguration()
                let session = URLSession(configuration: configuration, delegate: ProgressDelegate(onProgress, landed), delegateQueue: nil)
                task = session.dataTask(with: request)
                ownSession = session
            } else {
                task = (mode == .none ? URLSession.shared : direct).dataTask(with: request) { data, response, error in
                    landed(data, (response as? HTTPURLResponse)?.statusCode ?? 0, error)
                }
            }
            task.priority = priority
            call.start(task)
            ownSession?.finishTasksAndInvalidate()
            if timeoutMs > 0 {
                // URLSession's own limits are per idle stretch; this one is on the whole request.
                disk.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) {
                    guard call.claim() else { return }
                    call.stop()
                    noAnswer("The request timed out")
                }
            }
        }

        if let embedded {
            disk.async {
                if let data = EmbeddedAssets.read(embedded) { finish(.success(Answer(data: data, status: 200, cached: true))) }
                else { network() }
            }
        } else if mode == .forceCache {
            disk.async {
                if let copy = Core.cacheRead(area: area, url: url) { finish(.success(Answer(data: copy, status: 200, cached: true))) }
                else { network() }
            }
        } else {
            network()
        }
        return call
    }

    /// Keep `data` as the copy of `url` in the live world's area: the body of a 200 the caller
    /// already holds (an image whose load was joined by an asker that keeps it — the renderer's
    /// ImageLoader). Called where the asker is (the main thread); the write is made on `disk`.
    static func keep(url: String, data: Data) {
        let area = Core.cacheArea()
        disk.async { Core.cacheWrite(area: area, url: url, data) }
    }

    private final class ProgressDelegate: NSObject, URLSessionDataDelegate {
        private let onProgress: (Int, Int?) -> Void
        private let landed: (Data?, Int, Error?) -> Void
        private var chunks = Data()
        private var total: Int?
        private var status = 0
        private var lastReport: CFAbsoluteTime = 0
        init(_ onProgress: @escaping (Int, Int?) -> Void, _ landed: @escaping (Data?, Int, Error?) -> Void) {
            self.onProgress = onProgress
            self.landed = landed
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) { total = length }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            chunks.append(data)
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastReport >= 0.05 else { return }   // ~20 reports a second at most
            lastReport = now
            onProgress(chunks.count, total)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { landed(nil, status, error); return }
            onProgress(chunks.count, total)   // the final report, then the answer
            landed(chunks, status, nil)
        }
    }
}
