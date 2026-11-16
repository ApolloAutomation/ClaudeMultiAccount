import Foundation

public enum AtomicFileError: Error, Equatable {
    case posix(op: String, code: Int32)
    case notJSONObject
}

/// Atomic writes: temp file in the same directory, fsync, rename(2).
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL, permissions: mode_t = 0o644, createDirectories: Bool = true) throws {
        let dir = url.deletingLastPathComponent()
        if createDirectories {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tmp = dir.appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw AtomicFileError.posix(op: "open", code: errno) }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        do {
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw AtomicFileError.posix(op: "write", code: errno)
                    }
                    offset += n
                }
            }
            guard fsync(fd) == 0 else { throw AtomicFileError.posix(op: "fsync", code: errno) }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw AtomicFileError.posix(op: "close", code: errno) }
        guard rename(tmp.path, url.path) == 0 else { throw AtomicFileError.posix(op: "rename", code: errno) }
        ok = true
    }

    public static func write(_ string: String, to url: URL, permissions: mode_t = 0o644) throws {
        try write(Data(string.utf8), to: url, permissions: permissions)
    }

    /// Follows a symlink chain at `url` to the real file (which may not exist yet). Non-links return `url`.
    public static func resolvedTarget(_ url: URL) throws -> URL {
        var current = url
        for _ in 0..<32 {
            var st = stat()
            guard lstat(current.path, &st) == 0, st.st_mode & S_IFMT == S_IFLNK else { return current }
            let dest = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
            current = dest.hasPrefix("/") ? URL(fileURLWithPath: dest)
                : current.deletingLastPathComponent().appending(path: dest)
            current = current.standardizedFileURL
        }
        throw AtomicFileError.posix(op: "readlink", code: ELOOP)
    }

    /// Atomic write that keeps a symlink at `url` intact (writes next to the resolved real file instead)
    /// and keeps the existing file's permissions. New files get `defaultPermissions`.
    public static func writePreservingLink(_ data: Data, to url: URL, defaultPermissions: mode_t = 0o644) throws {
        let target = try resolvedTarget(url)
        var mode = defaultPermissions
        var st = stat()
        if stat(target.path, &st) == 0 { mode = st.st_mode & 0o7777 }
        try write(data, to: target, permissions: mode)
        // open(2) applies the umask; restore the exact original mode.
        if chmod(target.path, mode) != 0 { throw AtomicFileError.posix(op: "chmod", code: errno) }
    }

    /// Serialises a JSON object (via JSONSerialization, so unknown keys survive round trips).
    public static func jsonData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw AtomicFileError.notJSONObject }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func writeJSONObject(_ object: Any, to url: URL, permissions: mode_t = 0o644) throws {
        try write(jsonData(object), to: url, permissions: permissions)
    }

    /// Reads a top-level JSON dictionary. Missing file → nil. Non-dictionary → throws.
    public static func readJSONObject(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AtomicFileError.notJSONObject }
        return obj
    }
}
