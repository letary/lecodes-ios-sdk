// The local filesystem behind the SDK `files` global (files.d.ts): the reference is the desktop
// host (hosts/desktop/src/host/files.cpp), this is its port — the old macOS Swift port carried
// over — and it must keep answering the same way, so one project's saves behave the same on every
// host. ONE serial queue (two appends to one file land in call order; a read queued behind a write
// sees the finished file), off the main thread (file IO must not cost a frame); the ops settle
// their promise pair from the queue (Core.resolve / reject are thread-safe).
//
// The root of a RELATIVE path: the app's OWN folder — its Application Support container, the
// sandbox the app owns on iOS (never the process cwd, never the bundle: read-only and sealed).
import Foundation

/// A failed file op; `message` is what the JS promise rejects with.
struct LocalFileError: Error {
    let message: String
    /// "<path>: <strerror(errno)>" — read `errno` right after the failing call.
    static func posix(_ path: String) -> LocalFileError {
        LocalFileError(message: "\(path): \(String(cString: strerror(errno)))")
    }
}

/// One directory entry as the SDK's FileEntry. `size` / `modified` are Doubles: they cross into JS
/// as numbers, and an Int32 caps a size at 2 GB.
struct LocalFileEntry: Equatable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Double
    let modified: Double
}

final class LocalFiles {
    /// What a RELATIVE path is resolved against.
    var root: URL = LocalFiles.applicationSupportRoot

    static var applicationSupportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    private let queue = DispatchQueue(label: "codes.le.lecodes.files", qos: .userInitiated)

    /// An ABSOLUTE path verbatim, a RELATIVE one against `root`; `.` / `..` and a trailing slash
    /// are normalized away lexically. "" is the root itself.
    func resolve(_ path: String) -> String {
        if path.isEmpty { return root.standardizedFileURL.path }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        return url.standardizedFileURL.path
    }

    /// Run `work` on the queue, then hand its outcome to `settle` (still on the queue — the
    /// settle goes through the runtime's thread-safe dispatch).
    func submit<T>(_ work: @escaping () throws -> T, settle: @escaping (Result<T, LocalFileError>) -> Void) {
        queue.async {
            do { settle(.success(try work())) }
            catch let error as LocalFileError { settle(.failure(error)) }
            catch { settle(.failure(LocalFileError(message: error.localizedDescription))) }
        }
    }

    /// Block until every queued op has run (the way out: a save issued right before the app quits).
    func flush() { queue.sync {} }

    // MARK: - Operations (absolute paths; run on the queue)

    /// Creates the parent folders. Straight into the file, not tmp + rename: an append has to.
    static func write(_ full: String, _ data: Data, append: Bool) throws {
        let parent = (full as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard let file = fopen(full, append ? "ab" : "wb") else { throw LocalFileError.posix(full) }
        let written = data.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) }
        guard fclose(file) == 0, written == data.count else { throw LocalFileError.posix(full) }
    }

    /// nil when there is no such file ("not there" is an answer — a directory counts as not there);
    /// only an unreadable file throws.
    static func read(_ full: String) throws -> Data? {
        guard let info = status(full), info.isRegular else { return nil }
        do { return try Data(contentsOf: URL(fileURLWithPath: full)) }
        catch { throw LocalFileError(message: "can't read \(full): \(error.localizedDescription)") }
    }

    /// Already gone counts as deleted. FileManager.removeItem is ALWAYS recursive, so the
    /// non-recursive form goes through unlink / rmdir — a non-empty directory must fail there.
    static func delete(_ full: String, recursive: Bool) throws {
        var info = stat()
        guard lstat(full, &info) == 0 else {
            if errno == ENOENT { return }
            throw LocalFileError.posix(full)
        }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        if recursive && isDirectory {
            do { try FileManager.default.removeItem(atPath: full) }
            catch { throw LocalFileError(message: "\(full): \(error.localizedDescription)") }
        } else if (isDirectory ? rmdir(full) : unlink(full)) != 0 {
            throw LocalFileError.posix(full)
        }
    }

    /// Parents included; an existing directory is success.
    static func makeDirectory(_ full: String) throws {
        var reason = "not a directory"
        do { try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true) }
        catch { reason = error.localizedDescription }
        guard let info = status(full), info.isDirectory else { throw LocalFileError(message: "\(full): \(reason)") }
    }

    /// nil for a missing directory; a path that is a file throws. Sorted by relative path, BYTEWISE
    /// like the reference's std::string compare, so two runs and two hosts agree.
    static func list(_ full: String, recursive: Bool) throws -> [LocalFileEntry]? {
        guard let info = status(full) else { return nil }
        guard info.isDirectory else { throw LocalFileError(message: "\(full): not a directory") }
        var entries: [LocalFileEntry] = []
        func walk(_ directory: String, _ prefix: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory) {
                let path = (directory as NSString).appendingPathComponent(name)
                // Symlinks are followed for the kind; whatever is neither a file nor a directory is skipped.
                guard let info = status(path), info.isDirectory || info.isRegular else { continue }
                entries.append(info.entry(name: name, path: prefix + name))
                // …but not WALKED through (a link to a parent would never end); an unreadable
                // subfolder is skipped rather than failing the listing (the reference's iterator).
                if recursive && info.isDirectory && !isSymlink(path) { try? walk(path, prefix + name + "/") }
            }
        }
        do { try walk(full, "") }
        catch { throw LocalFileError(message: "\(full): \(error.localizedDescription)") }
        return entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    /// The same entry for one path (`path` = `name`), or nil when nothing is there.
    static func entry(_ full: String) throws -> LocalFileEntry? {
        guard let info = status(full) else { return nil }
        guard info.isDirectory || info.isRegular else { throw LocalFileError(message: "\(full): not a file or directory") }
        let name = (full as NSString).lastPathComponent
        return info.entry(name: name, path: name)
    }

    // MARK: - stat (FOLLOWS symlinks — kind / size / modified are the target's)

    private struct Status {
        let info: stat
        var isDirectory: Bool { (info.st_mode & S_IFMT) == S_IFDIR }
        var isRegular: Bool { (info.st_mode & S_IFMT) == S_IFREG }
        func entry(name: String, path: String) -> LocalFileEntry {
            let modified = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec / 1_000_000)
            return LocalFileEntry(name: name, path: path, isDirectory: isDirectory,
                                  size: isDirectory ? 0 : Double(info.st_size), modified: modified)
        }
    }
    private static func status(_ path: String) -> Status? {
        var info = stat()
        return stat(path, &info) == 0 ? Status(info: info) : nil
    }
    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }
}
