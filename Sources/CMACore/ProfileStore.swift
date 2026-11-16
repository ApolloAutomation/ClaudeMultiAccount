import Foundation

public enum ProfileStoreError: Error, Equatable {
    case duplicateID(UUID)
    case notFound(UUID)
}

enum CMAJSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Owns profiles.json (ordered array). All writes are atomic.
public actor ProfileStore {
    public let url: URL
    private var cache: [Profile]?

    public init(paths: AppPaths) { url = paths.profilesJSON }
    public init(url: URL) { self.url = url }

    /// Re-reads from disk. Missing file → empty.
    @discardableResult
    public func reload() throws -> [Profile] {
        let list: [Profile]
        if FileManager.default.fileExists(atPath: url.path) {
            list = try CMAJSON.decoder().decode([Profile].self, from: Data(contentsOf: url))
        } else {
            list = []
        }
        cache = list
        return list
    }

    public func all() throws -> [Profile] {
        if let cache { return cache }
        return try reload()
    }

    public func profile(id: UUID) throws -> Profile? { try all().first { $0.id == id } }

    public func add(_ profile: Profile) throws {
        var list = try all()
        guard !list.contains(where: { $0.id == profile.id }) else { throw ProfileStoreError.duplicateID(profile.id) }
        list.append(profile)
        try save(list)
    }

    public func update(_ profile: Profile) throws {
        var list = try all()
        guard let i = list.firstIndex(where: { $0.id == profile.id }) else { throw ProfileStoreError.notFound(profile.id) }
        list[i] = profile
        try save(list)
    }

    public func update(id: UUID, _ mutate: @Sendable (inout Profile) -> Void) throws {
        var list = try all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.notFound(id) }
        mutate(&list[i])
        list[i].id = id
        try save(list)
    }

    public func remove(id: UUID) throws {
        var list = try all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.notFound(id) }
        list.remove(at: i)
        try save(list)
    }

    /// Reorders to `ids`; unknown ids ignored, profiles not listed keep their relative order at the end.
    public func reorder(_ ids: [UUID]) throws {
        let list = try all()
        var out: [Profile] = []
        for id in ids { if let p = list.first(where: { $0.id == id }), !out.contains(where: { $0.id == id }) { out.append(p) } }
        for p in list where !out.contains(where: { $0.id == p.id }) { out.append(p) }
        try save(out)
    }

    private func save(_ list: [Profile]) throws {
        try AtomicFile.write(CMAJSON.encoder().encode(list), to: url, permissions: 0o600)
        cache = list
    }
}
