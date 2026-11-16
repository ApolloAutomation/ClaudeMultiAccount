import CMACore
import Darwin
import Foundation

public enum QuitTokenError: Error, Equatable {
    case posix(op: String, code: Int32)
    case unsafeFile(String)
}

/// Per-profile secret authenticating the `quitProfile` distributed notification. Stored in a 0600 file
/// `Locks/<UUID>.quit-token` that the manager and the profile's agent both read (whoever comes first creates it).
/// Notifications without the matching token are ignored.
public enum QuitToken {
    public static let userInfoKey = "token"

    public static func url(paths: AppPaths, profileID: UUID) -> URL {
        paths.locksDir.appending(path: "\(profileID.uuidString).quit-token")
    }

    /// Reads the token, creating it (random, 0600) if missing. Refuses symlinks, non-regular files,
    /// files owned by someone else or readable by group/other.
    public static func load(paths: AppPaths, profileID: UUID) throws -> String {
        let u = url(paths: paths, profileID: profileID)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try read(u) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let fd = open(u.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            // Lost a creation race: use the winner's token.
            if errno == EEXIST, let existing = try read(u) { return existing }
            throw QuitTokenError.posix(op: "open", code: errno)
        }
        defer { close(fd) }
        let data = Array(token.utf8)
        guard Darwin.write(fd, data, data.count) == data.count, fsync(fd) == 0 else {
            unlink(u.path)
            throw QuitTokenError.posix(op: "write", code: errno)
        }
        return token
    }

    static func read(_ u: URL) throws -> String? {
        var st = stat()
        guard lstat(u.path, &st) == 0 else { return nil }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw QuitTokenError.unsafeFile(u.path)
        }
        let fd = open(u.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw QuitTokenError.posix(op: "open", code: errno) }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 128)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0 else { return nil } // empty: being created concurrently
        let s = String(decoding: buf[0..<n], as: UTF8.self)
        return s.count == 64 && s.allSatisfy(\.isHexDigit) ? s : nil
    }

    /// Constant-time comparison of a received token against the expected one.
    public static func matches(_ received: Any?, expected: String) -> Bool {
        guard let r = received as? String else { return false }
        let a = Array(r.utf8), b = Array(expected.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Removes the token file (profile deleted).
    public static func remove(paths: AppPaths, profileID: UUID) {
        let u = url(paths: paths, profileID: profileID)
        if (try? SafePath.require(u, within: [paths.locksDir])) != nil { unlink(u.path) }
    }
}
