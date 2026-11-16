import CMACore
import CryptoKit
import Darwin
import Foundation

public enum DataDirLockError: Error, Equatable {
    case cannotOpen(errno: Int32)
}

/// Advisory `flock(2)` lock on `Locks/<key>.lock`, keyed by data dir. Held until `unlock()` or deinit.
/// Profile dirs use their UUID as key; other dirs a hash of the normalized path.
public final class DataDirLock: @unchecked Sendable {
    public let lockFile: URL
    private let mutex = NSLock()
    private var fd: Int32 = -1

    public init(paths: AppPaths, dataDir: URL) {
        lockFile = paths.locksDir.appending(path: Self.key(for: dataDir) + ".lock")
    }

    public static func key(for dataDir: URL) -> String {
        let last = dataDir.standardizedFileURL.lastPathComponent
        if let id = UUID(uuidString: last) { return id.uuidString }
        let digest = SHA256.hash(data: Data(ProcArgs.normalize(dataDir.path).utf8))
        return "dir-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public var isHeld: Bool { mutex.withLock { fd >= 0 } }

    /// Non-blocking. true = acquired (or already held by this object); false = held by someone else.
    public func tryLock() throws -> Bool {
        try mutex.withLock {
            if fd >= 0 { return true }
            try FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let f = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard f >= 0 else { throw DataDirLockError.cannotOpen(errno: errno) }
            if flock(f, LOCK_EX | LOCK_NB) != 0 { close(f); return false }
            fd = f
            return true
        }
    }

    /// Polls `tryLock` until `timeout`.
    public func lock(timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if try tryLock() { return true }
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    public func unlock() {
        mutex.withLock {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN); close(fd); fd = -1
        }
    }

    /// true if some other holder has the lock right now (probe; does not keep it).
    public func isLockedElsewhere() -> Bool {
        if isHeld { return false }
        guard (try? tryLock()) == true else { return true }
        unlock()
        return false
    }

    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}
