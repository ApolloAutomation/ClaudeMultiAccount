import CMACore
import Foundation

public enum RegularClaudeMoveError: Error, Equatable {
    case sourceMissing
    case destinationExists
    case claudeRunning
    case renameFailed(Int32)
    case verificationFailed(String)
}

public enum MoveRecovery: Sendable, Equatable {
    /// Nothing was moved; journal cleared.
    case rolledBack(entryID: UUID)
    /// Data is in the profile dir; caller must ensure the profile exists (+ app) then call `complete`.
    case needsProfile(entryID: UUID, profileID: UUID, dataDir: URL)
}

/// Moves `~/Library/Application Support/Claude` into `Profiles/<UUID>` byte-for-byte (single rename(2)),
/// journaled so an interruption is recoverable at launch. Cross-volume: copy, verify count+sizes, trash source.
public struct RegularClaudeMover: Sendable {
    public static let stepMoved = "moved"
    public static let stepCopying = "copying"
    public static let stepCopied = "copied"

    public let paths: AppPaths
    public let journal: OperationJournal
    let isRegularClaudeRunning: @Sendable () -> Bool
    let renameFn: @Sendable (String, String) -> Int32
    let trash: @Sendable (URL) throws -> Void

    public init(paths: AppPaths, isRegularClaudeRunning: @escaping @Sendable () -> Bool,
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.init(paths: paths, isRegularClaudeRunning: isRegularClaudeRunning, trash: trash,
                  renameFn: { Darwin.rename($0, $1) == 0 ? 0 : errno })
    }

    init(paths: AppPaths, isRegularClaudeRunning: @escaping @Sendable () -> Bool,
         trash: @escaping @Sendable (URL) throws -> Void, renameFn: @escaping @Sendable (String, String) -> Int32) {
        self.paths = paths
        self.journal = OperationJournal(paths: paths)
        self.isRegularClaudeRunning = isRegularClaudeRunning
        self.trash = trash
        self.renameFn = renameFn
    }

    func staging(_ id: UUID) -> URL { paths.buildDir.appending(path: "move-\(id.uuidString)", directoryHint: .isDirectory) }

    /// Moves the data. Returns the journal entry (step `moved`); call `complete` after the profile is saved.
    public func move(to profileID: UUID) throws -> JournalEntry {
        let fm = FileManager.default
        let src = paths.regularClaudeDir, dst = paths.dataDir(for: profileID)
        guard fm.fileExists(atPath: src.path) else { throw RegularClaudeMoveError.sourceMissing }
        guard !fm.fileExists(atPath: dst.path) else { throw RegularClaudeMoveError.destinationExists }
        guard !isRegularClaudeRunning() else { throw RegularClaudeMoveError.claudeRunning }
        try fm.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        var entry = try journal.begin(.moveRegularClaude, payload: ["profileID": profileID.uuidString,
                                                                    "source": src.path, "destination": dst.path])
        guard !isRegularClaudeRunning() else { try journal.complete(entry.id); throw RegularClaudeMoveError.claudeRunning }
        let err = renameFn(src.path, dst.path)
        if err == 0 {
            return try journal.advance(entry, to: Self.stepMoved)
        }
        guard err == EXDEV else { try journal.complete(entry.id); throw RegularClaudeMoveError.renameFailed(err) }

        entry = try journal.advance(entry, to: Self.stepCopying)
        let stage = staging(entry.id)
        do {
            try fm.createDirectory(at: paths.buildDir, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: stage)
            try Self.verifySameTree(src, stage)
            guard renameFn(stage.path, dst.path) == 0 else { throw RegularClaudeMoveError.renameFailed(errno) }
        } catch {
            if (try? SafePath.require(stage, within: [paths.buildDir])) != nil { try? fm.removeItem(at: stage) }
            try? journal.complete(entry.id)
            throw error
        }
        entry = try journal.advance(entry, to: Self.stepCopied)
        try trash(src)
        return try journal.advance(entry, to: Self.stepMoved)
    }

    public func complete(_ entry: JournalEntry) throws { try journal.complete(entry.id) }

    /// Resolves interrupted moves. Call at launch.
    public func recover() throws -> [MoveRecovery] {
        let fm = FileManager.default
        var out: [MoveRecovery] = []
        for var e in journal.pending() where e.kind == .moveRegularClaude {
            guard let idStr = e.payload["profileID"], let pid = UUID(uuidString: idStr) else { try journal.complete(e.id); continue }
            let src = paths.regularClaudeDir, dst = paths.dataDir(for: pid)
            let srcExists = fm.fileExists(atPath: src.path), dstExists = fm.fileExists(atPath: dst.path)
            switch e.step {
            case Self.stepMoved:
                out.append(.needsProfile(entryID: e.id, profileID: pid, dataDir: dst))
            case Self.stepCopying:
                let stage = staging(e.id)
                if fm.fileExists(atPath: stage.path) {
                    try SafePath.require(stage, within: [paths.buildDir])
                    try fm.removeItem(at: stage)
                }
                if dstExists && srcExists {
                    // The final rename happened but the journal wasn't advanced: verify, then treat as copied.
                    if (try? Self.verifySameTree(src, dst)) != nil {
                        e = try journal.advance(e, to: Self.stepCopied)
                        try trash(src)
                        e = try journal.advance(e, to: Self.stepMoved)
                        out.append(.needsProfile(entryID: e.id, profileID: pid, dataDir: dst))
                        continue
                    }
                }
                try journal.complete(e.id)
                out.append(.rolledBack(entryID: e.id))
            case Self.stepCopied:
                if srcExists { try trash(src) }
                e = try journal.advance(e, to: Self.stepMoved)
                out.append(.needsProfile(entryID: e.id, profileID: pid, dataDir: dst))
            default: // "begin": the rename either happened or not.
                if dstExists && !srcExists {
                    e = try journal.advance(e, to: Self.stepMoved)
                    out.append(.needsProfile(entryID: e.id, profileID: pid, dataDir: dst))
                } else {
                    try journal.complete(e.id)
                    out.append(.rolledBack(entryID: e.id))
                }
            }
        }
        return out
    }

    /// Same relative paths, same regular-file sizes, same symlink targets.
    static func verifySameTree(_ a: URL, _ b: URL) throws {
        func inventory(_ root: URL) -> [String: String] {
            var out: [String: String] = [:]
            let fm = FileManager.default
            guard let e = fm.enumerator(atPath: root.path) else { return out }
            for case let rel as String in e {
                let p = root.appending(path: rel).path
                var st = stat()
                guard lstat(p, &st) == 0 else { out[rel] = "?"; continue }
                switch st.st_mode & S_IFMT {
                case S_IFREG: out[rel] = "f\(st.st_size)"
                case S_IFDIR: out[rel] = "d"
                case S_IFLNK: out[rel] = "l" + ((try? fm.destinationOfSymbolicLink(atPath: p)) ?? "")
                default: out[rel] = "o"
                }
            }
            return out
        }
        let ia = inventory(a), ib = inventory(b)
        guard ia == ib else {
            let diff = Set(ia.keys).symmetricDifference(ib.keys).sorted().first ?? ia.first { ib[$0.key] != $0.value }?.key ?? "?"
            throw RegularClaudeMoveError.verificationFailed(diff)
        }
    }
}
