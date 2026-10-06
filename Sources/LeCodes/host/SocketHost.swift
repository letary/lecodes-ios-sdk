// The `socket` table (socket.d.ts): WebSockets over URLSession (services/WebSockets.swift).
import Foundation
import LeCodesCore

final class SocketHost: HostSocket {
    private let sockets = WebSockets()
    func open(url: String, onMessage: JSCallback) -> Int32 { sockets.open(url, onMessage: onMessage) }
    func send(id: Int32, message: String) { sockets.send(id, message) }
    func close(id: Int32) { sockets.close(id) }
    func dispose() { sockets.closeAll() }
}
