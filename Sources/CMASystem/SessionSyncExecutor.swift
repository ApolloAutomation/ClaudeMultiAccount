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
    /// Skipped because the destination account has a `deleted_<id>` tombstone (possibly added after the preview).
    public var skippedTombstoned: [String] = []
    /// Skipped because the source or the existing destination file couldn't be read as a JSON record.
    public var skippedUnreadable: [String] = []
    public var backups: [URL] = []
    public var indexesUpdated: [URL] = []
    /// Archive indexes left alone because they don't parse.
    public var indexesSkipped: [URL] = []
}

/// Executes a `SessionSyncPlan`. Reads sources only; backs up every replaced file; atomic writes; never deletes.
/// Both data dirs must be quit and locked by the caller for the duration.
public struct SessionSyncExecutor: Sendable {
    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) { self.allowedRoots = allowedRoots }
    public init(paths: AppPaths) { self.init(allowedRoots: SafePath.defaultRoots(paths)) }

    public func execute(_ plan: SessionSyncPlan) throws -> SessionSyncResult {
        var result = SessionSyncResult()
        var copiedIDs = Set<String>()
        var failure: Error?
        do {
            try copyAll(plan, result: &result, copiedIDs: &copiedIDs)
        } catch {
            failure = error // still mark the chats already copied as archived below
        }
        do {
            try updateIndexes(plan, copiedIDs: copiedIDs, result: &result)
        } catch {
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
        return result
    }

    /// True when any org dir of the destination account holds `deleted_<coreID>`.
    static func isTombstoned(_ sessionId: String, destination: URL) -> Bool {
        let account = destination.deletingLastPathComponent().deletingLastPathComponent()
        let core = SessionInventory.coreID(sessionId)
        let fm = FileManager.default
        for org in (try? fm.contentsOfDirectory(atPath: account.path)) ?? [] {
            let names = (try? fm.contentsOfDirectory(atPath: account.appending(path: org).path)) ?? []
            if names.contains(where: { $0.hasPrefix("deleted_") && SessionInventory.coreID($0) == core }) { return true }
        }
        return false
    }

    private func copyAll(_ plan: SessionSyncPlan, result: inout SessionSyncResult, copiedIDs: inout Set<String>) throws {
        let fm = FileManager.default
        for c in plan.copies {
            try SafePath.require(c.destination, within: allowedRoots)
            // Re-check tombstones right before writing: the chat may have been deleted after the preview.
            if Self.isTombstoned(c.sessionId, destination: c.destination) {
                result.skippedTombstoned.append(c.sessionId)
                continue
            }
            guard let data = try? Data(contentsOf: c.source),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                result.skippedUnreadable.append(c.sessionId)
                continue
            }
            var mode: mode_t = 0o644
            if let p = (try? fm.attributesOfItem(atPath: c.source.path))?[.posixPermissions] as? NSNumber { mode = mode_t(p.uint16Value) }

            if fm.fileExists(atPath: c.destination.path) {
                // Re-check before commit: never replace a record that is (now) as far along.
                let org = c.destination.deletingLastPathComponent()
                let acct = org.deletingLastPathComponent().lastPathComponent
                guard let existing = SessionRecord.load(url: c.destination, account: acct, org: org.lastPathComponent),
                      let incoming = SessionRecord.load(url: c.source, account: acct, org: org.lastPathComponent) else {
                    // A damaged destination record is left as is and reported, never overwritten.
                    result.skippedUnreadable.append(c.sessionId)
                    continue
                }
                if existing.contentHash == incoming.contentHash
                    || SessionRecord.compareProgress(incoming, existing) != .orderedDescending {
                    result.skippedChanged.append(c.sessionId)
                    continue
                }
                guard let backup = c.backup else { throw SessionSyncExecutionError.backupFailed(c.destination.path) }
                result.backups.append(try backupFile(c.destination, to: backup))
            }
            try AtomicFile.write(data, to: c.destination, permissions: mode)
            guard let back = try? Data(contentsOf: c.destination), back == data,
                  (try? JSONSerialization.jsonObject(with: back)) is [String: Any] else {
                throw SessionSyncExecutionError.verifyFailed(c.destination.path)
            }
            result.copied.append(c.sessionId)
            copiedIDs.insert(c.sessionId)
        }
    }

    private func updateIndexes(_ plan: SessionSyncPlan, copiedIDs: Set<String>, result: inout SessionSyncResult) throws {
        let fm = FileManager.default
        for u in plan.archiveUpdates {
            let ids = u.addIDs.filter { copiedIDs.contains($0) }
            guard !ids.isEmpty else { continue }
            try SafePath.require(u.indexURL, within: allowedRoots)
            let exists = fm.fileExists(atPath: u.indexURL.path)
            let existing = exists ? try Data(contentsOf: u.indexURL) : nil
            switch ArchivedSessionsIndex.mergeOutcome(existing, adding: ids) {
            case .unchanged:
                continue
            case .unreadable:
                result.indexesSkipped.append(u.indexURL)
            case .updated(let merged):
                var mode: mode_t = 0o644
                if exists {
                    guard let backup = u.backup else { throw SessionSyncExecutionError.backupFailed(u.indexURL.path) }
                    result.backups.append(try backupFile(u.indexURL, to: backup))
                    if let p = (try? fm.attributesOfItem(atPath: u.indexURL.path))?[.posixPermissions] as? NSNumber { mode = mode_t(p.uint16Value) }
                }
                try AtomicFile.write(merged, to: u.indexURL, permissions: mode)
                result.indexesUpdated.append(u.indexURL)
            }
        }
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
