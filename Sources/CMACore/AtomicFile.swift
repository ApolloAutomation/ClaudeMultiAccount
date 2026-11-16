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
