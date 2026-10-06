// The host BUFFER STORE every `systemId` of the platform points into (fetch.d.ts): fetched bodies,
// picked files, canvas bakes, local assets. The twin of Android's FetchBuffers: BOUNDED, not
// permanent — an LRU capped by total bytes, because JS holds only the id and a phone OOMs on a few
// dozen downloads otherwise. Eviction is safe: every consumer treats a missing id as "no data".
// Local-asset ids are PINNED (never evicted): an `asset()` compiles to a module-level
// `"id:" + local(name)` evaluated once, so a dropped asset could never be re-resolved.
//
// Thread-safe: producers arrive on URLSession / file / camera threads, consumers on the JS thread.
import Foundation

enum Buffers {
    /// Total retained payload cap; past it the least-recently-used unpinned buffers go.
    static let maxBytes = 64 * 1024 * 1024

    private static let lock = NSLock()
    private static var order: [Int32] = []           // least-recently-used first
    private static var buffers: [Int32: Data] = [:]
    private static var pinned = Set<Int32>()
    private static var totalBytes = 0
    // 0 is reserved: "no buffer" in the host contract (putBuffer's failure answer).
    private static var nextId: Int32 = 1

    /// Store a copy under a fresh id (ids are never reused).
    static func add(_ data: Data, pin: Bool = false) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        buffers[id] = data
        order.append(id)
        totalBytes += data.count
        if pin { pinned.insert(id) }
        evict(keep: id)
        return id
    }

    static func get(_ id: Int32) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let data = buffers[id] else { return nil }
        // A read counts as use: whatever is actively referenced stays hot.
        if let i = order.lastIndex(of: id), i != order.count - 1 { order.remove(at: i); order.append(id) }
        return data
    }

    /// The runtime released a fetched body (HostFetch.dispose), or the host is done with it.
    static func remove(_ id: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard !pinned.contains(id), let data = buffers.removeValue(forKey: id) else { return }
        totalBytes -= data.count
        if let i = order.lastIndex(of: id) { order.remove(at: i) }
    }

    static func isPinned(_ id: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pinned.contains(id)
    }

    /// Oldest first until the cap is met; the buffer just added and the pinned ones stay.
    private static func evict(keep: Int32) {
        guard totalBytes > maxBytes else { return }
        var i = 0
        while i < order.count && totalBytes > maxBytes {
            let id = order[i]
            if id == keep || pinned.contains(id) { i += 1; continue }
            if let data = buffers.removeValue(forKey: id) { totalBytes -= data.count }
            order.remove(at: i)
        }
    }
}
