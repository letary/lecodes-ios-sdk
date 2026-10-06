// WebSockets over URLSessionWebSocketTask (socket.d.ts): the `onMessage` handle of a connection is
// BORROWED — every event ("open", "message" with the text, "close" with the code, "error") rides
// Core.callBorrowed from the session's queue, and the handle is freed EXACTLY once when the
// connection dies (either side). Ids are host-allocated from 1, never reused.
import Foundation
import LeCodesCore

final class WebSocketConnection: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask!
    private var session: URLSession!
    private let onMessage: JSCallback
    private let onDead: () -> Void
    private var dead = false
    private let lock = NSLock()

    init(url: URL, onMessage: JSCallback, onDead: @escaping () -> Void) {
        self.onMessage = onMessage
        self.onDead = onDead
        super.init()
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.resume()
        listen()
        ping()
    }

    func send(_ text: String) {
        task.send(.string(text)) { error in if let error { print("[socket] send: \(error)") } }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        emit("open", nil)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        die(code: Int32(closeCode.rawValue))
    }

    private func listen() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.emit("message", .string(text))
                case .data(let data): if let text = String(data: data, encoding: .utf8) { self.emit("message", .string(text)) }
                @unknown default: break
                }
                self.listen()
            case .failure(let error):
                // After any error the socket is dead — always a close (the code names the error).
                self.die(code: Int32((error as NSError).code))
            }
        }
    }

    /// One "close" and one free, whichever path gets there first.
    private func die(code: Int32) {
        lock.lock()
        if dead { lock.unlock(); return }
        dead = true
        lock.unlock()
        Core.callBorrowed(onMessage, [.string("close"), .int(code)])
        Core.free(onMessage)
        session.finishTasksAndInvalidate()   // else the session keeps its delegate (us) forever
        onDead()
    }

    private func emit(_ channel: String, _ data: LeValue?) {
        lock.lock(); let gone = dead; lock.unlock()
        guard !gone else { return }
        Core.callBorrowed(onMessage, data.map { [.string(channel), $0] } ?? [.string(channel)])
    }

    private func ping() {
        task.sendPing { [weak self] error in
            guard let self, error == nil else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.task.state == .running else { return }
                self.ping()
            }
        }
    }
}

final class WebSockets {
    private var connections: [Int32: WebSocketConnection] = [:]
    private var nextId: Int32 = 1
    private let lock = NSLock()

    /// Open a connection; -1 (and the handle freed) for an invalid URL — the SDK hears no "error"
    /// then, only the failed open.
    func open(_ url: String, onMessage: JSCallback) -> Int32 {
        guard let parsed = URL(string: url) else {
            Core.callBorrowed(onMessage, [.string("error")])
            Core.free(onMessage)
            return -1
        }
        lock.lock()
        let id = nextId
        nextId += 1
        lock.unlock()
        let connection = WebSocketConnection(url: parsed, onMessage: onMessage) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.connections[id] = nil; self.lock.unlock()
        }
        lock.lock(); connections[id] = connection; lock.unlock()
        return id
    }

    func send(_ id: Int32, _ text: String) {
        lock.lock(); let c = connections[id]; lock.unlock()
        c?.send(text)
    }

    func close(_ id: Int32) {
        lock.lock(); let c = connections[id]; lock.unlock()
        c?.close()
    }

    func closeAll() {
        lock.lock(); let all = Array(connections.values); lock.unlock()
        all.forEach { $0.close() }
    }
}
