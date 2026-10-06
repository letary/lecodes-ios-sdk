// The `files` table (files.d.ts): the SDK `files` global over LocalFiles — the app's Application
// Support container is the folder a RELATIVE path lands in. Every op runs on the one serial queue
// and settles its pair from there (Core.resolve / reject are thread-safe); a write / remove drops
// the name's cached `local` id first, so the next read sees the new bytes.
import Foundation
import LeCodesCore

final class FilesHost: HostFiles {
    weak var engine: LeCodesEngine?
    private var files: LocalFiles { engine?.localFiles ?? LocalFiles() }

    private func settle<T>(_ onComplete: JSCallback, _ onReject: JSCallback, _ work: @escaping () throws -> T, _ value: @escaping (T) -> [LeValue]) {
        files.submit(work) { result in
            switch result {
            case .success(let out): Core.resolve(onComplete, reject: onReject, value(out))
            case .failure(let error): Core.reject(onComplete, reject: onReject, message: error.message)
            }
        }
    }

    private static func entry(_ e: LocalFileEntry) -> LeValue {
        .object([("name", .string(e.name)), ("path", .string(e.path)), ("kind", .string(e.isDirectory ? "dir" : "file")),
                 ("size", .double(e.size)), ("modified", .double(e.modified))])
    }

    func write(path: String, data: UnsafeBufferPointer<UInt8>, append: Bool, onComplete: JSCallback, onReject: JSCallback) {
        let bytes = Data(buffer: data)   // ours: the span is only valid for the duration of the call
        engine?.fetch.dropLocalCache(path)
        let full = files.resolve(path)
        settle(onComplete, onReject, { try LocalFiles.write(full, bytes, append: append) }) { _ in [] }
    }
    func readBytes(path: String, onComplete: JSCallback, onReject: JSCallback) {
        let full = files.resolve(path)
        settle(onComplete, onReject, { try LocalFiles.read(full) }) { data in [data.map { .bytes([UInt8]($0)) } ?? .null] }
    }
    func readText(path: String, onComplete: JSCallback, onReject: JSCallback) {
        let full = files.resolve(path)
        settle(onComplete, onReject, { try LocalFiles.read(full) }) { data in [data.map { .string(String(decoding: $0, as: UTF8.self)) } ?? .null] }
    }
    func remove(path: String, recursive: Bool, onComplete: JSCallback, onReject: JSCallback) {
        engine?.fetch.dropLocalCache(path, withChildren: recursive)
        let full = files.resolve(path)
        settle(onComplete, onReject, { try LocalFiles.delete(full, recursive: recursive) }) { _ in [] }
    }
    func mkdir(path: String, onComplete: JSCallback, onReject: JSCallback) {
        let full = files.resolve(path)
        settle(onComplete, onReject, { try LocalFiles.makeDirectory(full) }) { _ in [] }
    }
    func list(path: String, recursive: Bool, onComplete: JSCallback, onReject: JSCallback) {
        let full = files.resolve(path)
        settle(onComplete, onReject, { try LocalFiles.list(full, recursive: recursive) }) { entries in
            [entries.map { .array($0.map(FilesHost.entry)) } ?? .null]
        }
    }
    func stat(path: String, onComplete: JSCallback, onReject: JSCallback) {
        let full = files.resolve(path)
        settle(onComplete, onReject, { try LocalFiles.entry(full) }) { e in [e.map(FilesHost.entry) ?? .null] }
    }
}
