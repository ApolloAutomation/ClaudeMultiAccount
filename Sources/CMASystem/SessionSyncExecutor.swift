import CMACore
import Foundation

public enum SessionSyncExecutionError: Error, Equatable {
    case sourceUnreadable(String)
    case notJSON(String)
    case backupFailed(String)
    case verifyFailed(String)
}

public struct SessionSyncResult: Sendable, Equatable {
    public var copied: [String] = []
    /// Skipped at execution time because the destination became further along (or identical) since planning.
    public var skippedChanged: [String] = []
    public var backups: [URL] = []
    public var indexesUpdated: [URL] = []
}

/// Executes a `SessionSyncPlan`. Reads sources only; backs up every replaced file; atomic writes; never deletes.
/// Both data dirs must be quit and locked by the caller for the duration.
public struct SessionSyncExecutor: Sendable {
    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) { self.allowedRoots = allowedRoots }
    public init(paths: AppPaths) { self.init(allowedRoots: SafePath.defaultRoots(paths)) }

    public func execute(_ plan: SessionSyncPlan) throws -> SessionSyncResult {
        let fm = FileManager.default
        var result = SessionSyncResult()
        var copiedIDs = Set<String>()
        for c in plan.copies {
            guard let data = try? Data(contentsOf: c.source) else { throw SessionSyncExecutionError.sourceUnreadable(c.source.path) }
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw SessionSyncExecutionError.notJSON(c.source.path)
            }
            try SafePath.require(c.destination, within: allowedRoots)
            var mode: mode_t = 0o644
            if let p = (try? fm.attributesOfItem(atPath: c.source.path))?[.posixPermissions] as? NSNumber { mode = mode_t(p.uint16Value) }

            if fm.fileExists(atPath: c.destination.path) {
                // Re-check before commit: never replace a record that is (now) as far along.
                let org = c.destination.deletingLastPathComponent()
                let acct = org.deletingLastPathComponent().lastPathComponent
                if let existing = SessionRecord.load(url: c.destination, account: acct, org: org.lastPathComponent),
                   let incoming = SessionRecord.load(url: c.source, account: acct, org: org.lastPathComponent) {
                    if existing.contentHash == incoming.contentHash
                        || SessionRecord.compareProgress(incoming, existing) != .orderedDescending {
                        result.skippedChanged.append(c.sessionId)
                        continue
                    }
                }
                guard let backup = c.backup else { throw SessionSyncExecutionError.backupFailed(c.destination.path) }
                let b = try backupFile(c.destination, to: backup)
                result.backups.append(b)
            }
            try AtomicFile.write(data, to: c.destination, permissions: mode)
            guard let back = try? Data(contentsOf: c.destination), back == data,
                  (try? JSONSerialization.jsonObject(with: back)) is [String: Any] else {
                throw SessionSyncExecutionError.verifyFailed(c.destination.path)
            }
            result.copied.append(c.sessionId)
            copiedIDs.insert(c.sessionId)
        }
        for u in plan.archiveUpdates {
            let ids = u.addIDs.filter { copiedIDs.contains($0) }
            guard !ids.isEmpty else { continue }
            try SafePath.require(u.indexURL, within: allowedRoots)
            let existing = try? Data(contentsOf: u.indexURL)
            guard let merged = ArchivedSessionsIndex.merge(existing, adding: ids) else { continue }
            if existing != nil, let backupDir = result.backups.first?.deletingLastPathComponent() ?? plan.copies.first?.backup?.deletingLastPathComponent() {
                result.backups.append(try backupFile(u.indexURL, to: backupDir.appending(path: "\(UUID().uuidString)-\(ArchivedSessionsIndex.fileName)")))
            }
            try AtomicFile.write(merged, to: u.indexURL)
            result.indexesUpdated.append(u.indexURL)
        }
        return result
    }

    /// Copies `file` to `backup` (never overwriting an existing backup) and verifies the bytes.
    func backupFile(_ file: URL, to backup: URL) throws -> URL {
        let fm = FileManager.default
        var target = backup
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = backup.deletingLastPathComponent().appending(path: "\(backup.deletingPathExtension().lastPathComponent)-\(n).\(backup.pathExtension)")
            n += 1
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: file, to: target)
        guard let a = try? Data(contentsOf: file), let b = try? Data(contentsOf: target), a == b else {
            throw SessionSyncExecutionError.backupFailed(file.path)
        }
        return target
    }
}
