import Foundation

/// `manifest.json` at the root of a profile backup zip, next to the `<UUID>/` data folder.
public struct BackupManifest: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1
    public static let fileName = "manifest.json"

    public var formatVersion: Int
    public var profileID: UUID
    public var name: String
    public var color: ProfileColor
    public var showBorder: Bool
    public var borderWidth: BorderWidth
    public var createdAt: Date
    public var appVersion: String

    public init(profile: Profile, createdAt: Date = Date(), appVersion: String = "1.0") {
        formatVersion = Self.currentFormatVersion
        profileID = profile.id; name = profile.name; color = profile.color
        showBorder = profile.showBorder; borderWidth = profile.borderWidth
        self.createdAt = createdAt; self.appVersion = appVersion
    }

    public func encoded() throws -> Data { try CMAJSON.encoder().encode(self) }

    public static func decode(_ data: Data) throws -> BackupManifest {
        try CMAJSON.decoder().decode(BackupManifest.self, from: data)
    }

    public var isSupported: Bool { formatVersion >= 1 && formatVersion <= Self.currentFormatVersion }

    /// New profile for a restore: fresh UUID, deduplicated name.
    public func restoredProfile(existingNames: [String], id: UUID = UUID()) -> Profile {
        Profile(id: id, name: NameValidator.deduplicated(name, taken: existingNames), color: color,
                showBorder: showBorder, borderWidth: borderWidth)
    }
}

public enum BackupEntryError: Error, Equatable {
    case empty
    case absolutePath(String)
    case parentTraversal(String)
    case invalidCharacter(String)
    case multipleRoots([String])
    case unexpectedTopLevel(String)
    case missingManifest
    case missingDataRoot
}

/// Validates `unzip -Z1` entry names before extracting (zip-slip guard).
public enum BackupEntryValidator {
    /// Returns the data root folder name (a UUID string).
    public static func validate(_ entries: [String]) throws -> String {
        let names = entries.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { throw BackupEntryError.empty }
        var roots = Set<String>()
        var hasManifest = false
        for n in names {
            if n.hasPrefix("/") || n.hasPrefix("~") { throw BackupEntryError.absolutePath(n) }
            if n.contains("\\") || n.contains("\0") || n.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw BackupEntryError.invalidCharacter(n)
            }
            let comps = n.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if comps.contains("..") { throw BackupEntryError.parentTraversal(n) }
            if comps.dropLast().contains("") || comps.contains(".") { throw BackupEntryError.invalidCharacter(n) }
            if comps.count == 1 {
                if n == BackupManifest.fileName { hasManifest = true; continue }
                throw BackupEntryError.unexpectedTopLevel(n)
            }
            roots.insert(comps[0])
        }
        guard hasManifest else { throw BackupEntryError.missingManifest }
        guard !roots.isEmpty else { throw BackupEntryError.missingDataRoot }
        guard roots.count == 1, let root = roots.first else { throw BackupEntryError.multipleRoots(roots.sorted()) }
        guard UUID(uuidString: root) != nil else { throw BackupEntryError.unexpectedTopLevel(root) }
        return root
    }
}
