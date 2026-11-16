import CryptoKit
import Foundation

/// One `claude-code-sessions/<account>/<org>/local_<uuid>.json` record file.
public struct SessionRecord: Sendable, Equatable {
    /// File name without `.json` (e.g. `local_<uuid>`).
    public let sessionId: String
    public let account: String
    public let org: String
    public let url: URL
    public let cliSessionId: String?
    public let createdAt: Double
    public let lastActivityAt: Double
    public let completedTurns: Int
    public let lastTurnEdgeAt: Double
    public let isArchived: Bool
    public let cwd: String?
    public let modifiedAt: Date
    public let contentHash: String

    public init(sessionId: String, account: String, org: String, url: URL, cliSessionId: String? = nil,
                createdAt: Double = 0, lastActivityAt: Double = 0, completedTurns: Int = 0, lastTurnEdgeAt: Double = 0,
                isArchived: Bool = false, cwd: String? = nil, modifiedAt: Date = .distantPast, contentHash: String = "") {
        self.sessionId = sessionId; self.account = account; self.org = org; self.url = url
        self.cliSessionId = cliSessionId; self.createdAt = createdAt; self.lastActivityAt = lastActivityAt
        self.completedTurns = completedTurns; self.lastTurnEdgeAt = lastTurnEdgeAt; self.isArchived = isArchived
        self.cwd = cwd; self.modifiedAt = modifiedAt; self.contentHash = contentHash
    }

    public static func isRecordFileName(_ name: String) -> Bool {
        name.hasPrefix("local_") && name.hasSuffix(".json") && name.count > "local_.json".count
    }

    public static func load(url: URL, account: String, org: String) -> SessionRecord? {
        let name = url.lastPathComponent
        guard isRecordFileName(name), let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func num(_ k: String) -> Double { (obj[k] as? NSNumber)?.doubleValue ?? 0 }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SessionRecord(sessionId: String(name.dropLast(5)), account: account, org: org, url: url,
                             cliSessionId: obj["cliSessionId"] as? String, createdAt: num("createdAt"),
                             lastActivityAt: num("lastActivityAt"), completedTurns: Int(num("completedTurns")),
                             lastTurnEdgeAt: num("lastTurnEdgeAt"), isArchived: (obj["isArchived"] as? Bool) ?? false,
                             cwd: obj["cwd"] as? String, modifiedAt: mtime, contentHash: hash)
    }

    /// `.orderedDescending` when `a` is further along than `b`:
    /// completedTurns, then lastActivityAt, then lastTurnEdgeAt, then mtime.
    public static func compareProgress(_ a: SessionRecord, _ b: SessionRecord) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x == y ? .orderedSame : (x > y ? .orderedDescending : .orderedAscending) }
        for r in [cmp(a.completedTurns, b.completedTurns), cmp(a.lastActivityAt, b.lastActivityAt),
                  cmp(a.lastTurnEdgeAt, b.lastTurnEdgeAt), cmp(a.modifiedAt, b.modifiedAt)] where r != .orderedSame {
            return r
        }
        return .orderedSame
    }

    /// The `<uuid>` core used to match tombstones.
    public var coreID: String { SessionInventory.coreID(sessionId) }
}

/// `archived-sessions.idx`: `{"v":1,"archived":[ids]}`.
public enum ArchivedSessionsIndex {
    public static let fileName = "archived-sessions.idx"

    public static func ids(_ data: Data?) -> Set<String> {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["archived"] as? [Any] else { return [] }
        return Set(arr.compactMap { $0 as? String })
    }

    public enum MergeOutcome: Equatable, Sendable {
        case unchanged
        case updated(Data)
        /// The existing index doesn't parse as `{"archived":[...]}`: refuse to rewrite it.
        case unreadable
    }

    /// Adds ids, keeping existing entries (including non-string ones), their order and unknown keys.
    public static func mergeOutcome(_ existing: Data?, adding: [String]) -> MergeOutcome {
        var obj: [String: Any] = ["v": 1]
        var arr: [Any] = []
        if let existing {
            guard let o = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return .unreadable }
            obj = o
            if let a = o["archived"] {
                guard let a = a as? [Any] else { return .unreadable }
                arr = a
            }
        }
        let have = Set(arr.compactMap { $0 as? String })
        var seen = Set<String>()
        let uniqueNew = adding.filter { !have.contains($0) && seen.insert($0).inserted }
        if uniqueNew.isEmpty, existing != nil { return .unchanged }
        arr.append(contentsOf: uniqueNew as [Any])
        obj["archived"] = arr
        if obj["v"] == nil { obj["v"] = 1 }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return .unreadable }
        return .updated(data)
    }

    /// Convenience: the merged bytes, or nil when nothing changes or the existing index is unreadable.
    public static func merge(_ existing: Data?, adding: [String]) -> Data? {
        if case .updated(let d) = mergeOutcome(existing, adding: adding) { return d }
        return nil
    }
}

/// Everything under one data dir's `claude-code-sessions/`.
public struct SessionInventory: Sendable, Equatable {
    public var root: URL
    public var records: [SessionRecord]
    /// account → tombstoned core ids.
    public var tombstones: [String: Set<String>]
    /// "account/org" → archived ids from archived-sessions.idx.
    public var archived: [String: Set<String>]
    /// account → org dir names.
    public var orgsByAccount: [String: [String]]

    public init(root: URL, records: [SessionRecord] = [], tombstones: [String: Set<String>] = [:],
                archived: [String: Set<String>] = [:], orgsByAccount: [String: [String]] = [:]) {
        self.root = root; self.records = records; self.tombstones = tombstones; self.archived = archived; self.orgsByAccount = orgsByAccount
    }

    /// Strips `deleted_`, `local_` prefixes and a `.json` suffix.
    public static func coreID(_ name: String) -> String {
        var s = Substring(name)
        if s.hasSuffix(".json") { s = s.dropLast(5) }
        if s.hasPrefix("deleted_") { s = s.dropFirst(8) }
        if s.hasPrefix("local_") { s = s.dropFirst(6) }
        return String(s).lowercased()
    }

    public static func scan(_ root: URL) -> SessionInventory {
        let fm = FileManager.default
        var inv = SessionInventory(root: root)
        func dirs(_ u: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { name in
                var isDir: ObjCBool = false
                return !name.hasPrefix(".") && fm.fileExists(atPath: u.appending(path: name).path, isDirectory: &isDir) && isDir.boolValue
            }.sorted()
        }
        for account in dirs(root) {
            let accURL = root.appending(path: account, directoryHint: .isDirectory)
            var orgs: [String] = []
            var tomb = Set<String>()
            for org in dirs(accURL) {
                let orgURL = accURL.appending(path: org, directoryHint: .isDirectory)
                orgs.append(org)
                let names = (try? fm.contentsOfDirectory(atPath: orgURL.path)) ?? []
                for name in names.sorted() {
                    if name.hasPrefix("deleted_") {
                        tomb.insert(coreID(name))
                    } else if SessionRecord.isRecordFileName(name),
                              let r = SessionRecord.load(url: orgURL.appending(path: name), account: account, org: org) {
                        inv.records.append(r)
                    }
                }
                let idx = ArchivedSessionsIndex.ids(try? Data(contentsOf: orgURL.appending(path: ArchivedSessionsIndex.fileName)))
                if !idx.isEmpty { inv.archived["\(account)/\(org)"] = idx }
            }
            inv.orgsByAccount[account] = orgs
            if !tomb.isEmpty { inv.tombstones[account] = tomb }
        }
        return inv
    }

    public func records(account: String) -> [SessionRecord] {
        records.filter { $0.account.caseInsensitiveCompare(account) == .orderedSame }
    }

    public func accountDirName(_ account: String) -> String? {
        orgsByAccount.keys.first { $0.caseInsensitiveCompare(account) == .orderedSame }
    }

    public func isTombstoned(_ sessionId: String, account: String) -> Bool {
        guard let key = accountDirName(account) else { return false }
        return tombstones[key]?.contains(Self.coreID(sessionId)) ?? false
    }

    public func isArchived(_ r: SessionRecord) -> Bool {
        r.isArchived || (archived["\(r.account)/\(r.org)"]?.contains(r.sessionId) ?? false)
    }
}

public enum SyncSide: Sendable, Equatable, Hashable {
    case a, b
    public var other: SyncSide { self == .a ? .b : .a }
    var label: String { self == .a ? "a" : "b" }
}

public struct SessionCopy: Sendable, Equatable {
    public var sessionId: String
    public var from: SyncSide
    public var source: URL
    public var destination: URL
    /// Existing destination file is replaced (backed up first to `backup`).
    public var replaces: Bool
    public var backup: URL?
}

public struct ArchiveIndexUpdate: Sendable, Equatable {
    public var indexURL: URL
    public var addIDs: [String]
    /// Where the existing index is backed up before it is replaced.
    public var backup: URL?
    public init(indexURL: URL, addIDs: [String], backup: URL? = nil) {
        self.indexURL = indexURL; self.addIDs = addIDs; self.backup = backup
    }
}

public struct SessionSyncPlan: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case twoWay, oneWay(from: SyncSide) }
    public var mode: Mode
    public var copies: [SessionCopy] = []
    public var skippedTombstoned: [String] = []
    public var skippedIdentical: [String] = []
    public var skippedNotNewer: [String] = []
    public var archiveUpdates: [ArchiveIndexUpdate] = []
    public var isEmpty: Bool { copies.isEmpty && archiveUpdates.isEmpty }
}

public enum SessionSyncError: Error, Equatable {
    case unknownAccount(SyncSide)
    case directionRequired
    case noDestinationOrg
    case ambiguousDestinationOrg([String])
}

/// Pure planner. Never deletes; replaces only with a backup; skips tombstoned ids.
public enum SessionSyncPlanner {
    public static func backupRoot(paths: AppPaths, date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return paths.backupsDir.appending(path: "session-sync/\(f.string(from: date))", directoryHint: .isDirectory)
    }

    public static func sameAccount(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// - Parameters:
    ///   - oneWayFrom: required when accounts differ; optional for same account (forces one-way).
    ///   - destinationOrg: org to rehome into when accounts differ; inferred if the destination account has exactly one org.
    public static func plan(a: SessionInventory, aAccount: String?, b: SessionInventory, bAccount: String?,
                            oneWayFrom: SyncSide? = nil, destinationOrg: String? = nil, backupRoot: URL) throws -> SessionSyncPlan {
        guard let aAccount else { throw SessionSyncError.unknownAccount(.a) }
        guard let bAccount else { throw SessionSyncError.unknownAccount(.b) }
        let inv: [SyncSide: SessionInventory] = [.a: a, .b: b]
        let acct: [SyncSide: String] = [.a: aAccount.lowercased(), .b: bAccount.lowercased()]

        if sameAccount(aAccount, bAccount) {
            var plan = SessionSyncPlan(mode: oneWayFrom.map { .oneWay(from: $0) } ?? .twoWay)
            let sides: [SyncSide] = oneWayFrom.map { [$0] } ?? [.a, .b]
            for src in sides {
                let dst = src.other
                let dstInv = inv[dst]!
                let dstAccDir = dstInv.accountDirName(acct[dst]!) ?? acct[dst]!
                for r in inv[src]!.records(account: acct[src]!) {
                    let existing = dstInv.records(account: acct[dst]!).first { $0.org == r.org && $0.sessionId == r.sessionId }
                    let destURL = dstInv.root.appending(path: "\(dstAccDir)/\(r.org)/\(r.sessionId).json")
                    consider(r, src: src, srcInv: inv[src]!, existing: existing, dstInv: dstInv, dstAccount: acct[dst]!,
                             destURL: destURL, backupRoot: backupRoot, dstSide: dst, plan: &plan)
                }
            }
            plan.archiveUpdates.sort { $0.indexURL.path < $1.indexURL.path }
            return plan
        }

        guard let src = oneWayFrom else { throw SessionSyncError.directionRequired }
        let dst = src.other
        let dstInv = inv[dst]!
        let dstAccDir = dstInv.accountDirName(acct[dst]!) ?? acct[dst]!
        let org: String
        if let destinationOrg {
            org = destinationOrg
        } else {
            let orgs = dstInv.orgsByAccount[dstAccDir] ?? []
            if orgs.isEmpty { throw SessionSyncError.noDestinationOrg }
            if orgs.count > 1 { throw SessionSyncError.ambiguousDestinationOrg(orgs) }
            org = orgs[0]
        }
        var plan = SessionSyncPlan(mode: .oneWay(from: src))
        for r in inv[src]!.records(account: acct[src]!) {
            let existing = dstInv.records(account: acct[dst]!).first { $0.org == org && $0.sessionId == r.sessionId }
            let destURL = dstInv.root.appending(path: "\(dstAccDir)/\(org)/\(r.sessionId).json")
            consider(r, src: src, srcInv: inv[src]!, existing: existing, dstInv: dstInv, dstAccount: acct[dst]!,
                     destURL: destURL, backupRoot: backupRoot, dstSide: dst, plan: &plan)
        }
        plan.archiveUpdates.sort { $0.indexURL.path < $1.indexURL.path }
        return plan
    }

    private static func consider(_ r: SessionRecord, src: SyncSide, srcInv: SessionInventory, existing: SessionRecord?,
                                 dstInv: SessionInventory, dstAccount: String, destURL: URL, backupRoot: URL,
                                 dstSide: SyncSide, plan: inout SessionSyncPlan) {
        if dstInv.isTombstoned(r.sessionId, account: dstAccount) {
            if !plan.skippedTombstoned.contains(r.sessionId) { plan.skippedTombstoned.append(r.sessionId) }
            return
        }
        var backup: URL?
        let rel = destURL.path.hasPrefix(dstInv.root.path + "/") ? String(destURL.path.dropFirst(dstInv.root.path.count + 1)) : destURL.lastPathComponent
        // Any file already at the destination (even an unparseable one) gets a backup path.
        if FileManager.default.fileExists(atPath: destURL.path) { backup = backupRoot.appending(path: "\(dstSide.label)/\(rel)") }
        if let existing {
            if existing.contentHash == r.contentHash && !r.contentHash.isEmpty {
                if !plan.skippedIdentical.contains(r.sessionId) { plan.skippedIdentical.append(r.sessionId) }
                return
            }
            let order = SessionRecord.compareProgress(r, existing)
            guard order == .orderedDescending else {
                // In two-way mode the other side copies when it is further along; only report true ties.
                if (plan.mode != .twoWay || order == .orderedSame) && !plan.skippedNotNewer.contains(r.sessionId) {
                    plan.skippedNotNewer.append(r.sessionId)
                }
                return
            }
            backup = backupRoot.appending(path: "\(dstSide.label)/\(rel)")
        }
        plan.copies.append(SessionCopy(sessionId: r.sessionId, from: src, source: r.url, destination: destURL,
                                       replaces: existing != nil, backup: backup))
        if srcInv.isArchived(r) {
            let idxURL = destURL.deletingLastPathComponent().appending(path: ArchivedSessionsIndex.fileName)
            let destOrgKey = "\(destURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)/\(destURL.deletingLastPathComponent().lastPathComponent)"
            if dstInv.archived[destOrgKey]?.contains(r.sessionId) == true { return }
            if let i = plan.archiveUpdates.firstIndex(where: { $0.indexURL == idxURL }) {
                plan.archiveUpdates[i].addIDs.append(r.sessionId)
            } else {
                let idxRel = idxURL.path.hasPrefix(dstInv.root.path + "/") ? String(idxURL.path.dropFirst(dstInv.root.path.count + 1)) : idxURL.lastPathComponent
                plan.archiveUpdates.append(ArchiveIndexUpdate(indexURL: idxURL, addIDs: [r.sessionId],
                                                              backup: backupRoot.appending(path: "\(dstSide.label)/\(idxRel)")))
            }
        }
    }
}
