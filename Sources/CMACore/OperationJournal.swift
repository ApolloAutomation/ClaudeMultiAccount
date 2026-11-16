import Foundation

public enum OperationKind: String, Codable, Sendable {
    case moveRegularClaude, restoreBackup, deleteProfile, sessionSync, renameProfile
}

public struct JournalEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: OperationKind
    public var createdAt: Date
    public var updatedAt: Date
    /// Last completed step name (operation-specific).
    public var step: String
    public var payload: [String: String]

    public init(id: UUID = UUID(), kind: OperationKind, step: String = "begin", payload: [String: String] = [:], at date: Date = Date()) {
        self.id = id; self.kind = kind; createdAt = date; updatedAt = date; self.step = step; self.payload = payload
    }
}

/// One JSON file per in-flight multi-step operation in `Journal/`. Leftover files at launch = recovery needed.
public struct OperationJournal: Sendable {
    public let dir: URL
    public init(dir: URL) { self.dir = dir }
    public init(paths: AppPaths) { dir = paths.journalDir }

    func url(_ id: UUID) -> URL { dir.appending(path: "\(id.uuidString).json") }

    @discardableResult
    public func begin(_ kind: OperationKind, payload: [String: String] = [:], at date: Date = Date()) throws -> JournalEntry {
        let e = JournalEntry(kind: kind, payload: payload, at: date)
        try write(e)
        return e
    }

    public func write(_ entry: JournalEntry) throws {
        try AtomicFile.write(CMAJSON.encoder().encode(entry), to: url(entry.id), permissions: 0o600)
    }

    @discardableResult
    public func advance(_ entry: JournalEntry, to step: String, payload: [String: String] = [:], at date: Date = Date()) throws -> JournalEntry {
        var e = entry
        e.step = step
        e.updatedAt = date
        e.payload.merge(payload) { _, new in new }
        try write(e)
        return e
    }

    public func complete(_ id: UUID) throws {
        let u = url(id)
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        try SafePath.require(u, within: [dir])
        try FileManager.default.removeItem(at: u)
    }

    /// Pending entries, oldest first. Unreadable files are skipped.
    public func pending() -> [JournalEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap {
            (try? Data(contentsOf: dir.appending(path: $0))).flatMap { try? CMAJSON.decoder().decode(JournalEntry.self, from: $0) }
        }.sorted { $0.createdAt < $1.createdAt }
    }
}
