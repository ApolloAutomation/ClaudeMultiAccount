import Foundation

public enum NameValidationError: Error, Equatable, Sendable {
    case empty, tooLong, invalidCharacter, leadingDot, duplicate

    public var message: String {
        switch self {
        case .empty: "Enter a name."
        case .tooLong: "Use \(NameValidator.maxLength) characters or fewer."
        case .invalidCharacter: "Names can't contain “/” or “:”."
        case .leadingDot: "Names can't start with a period."
        case .duplicate: "Another profile already uses this name."
        }
    }
}

public enum NameValidator {
    public static let maxLength = 64

    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns nil when valid. Names are compared after trimming, case-insensitively; `excluding` is the profile being renamed.
    public static func validate(_ name: String, existingNames: [(id: UUID, name: String)], excluding: UUID? = nil) -> NameValidationError? {
        let n = normalized(name)
        if n.isEmpty { return .empty }
        if n.count > maxLength { return .tooLong }
        if n.contains("/") || n.contains(":") || n.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .invalidCharacter
        }
        if n.hasPrefix(".") { return .leadingDot }
        let key = n.lowercased()
        if existingNames.contains(where: { $0.id != excluding && normalized($0.name).lowercased() == key }) { return .duplicate }
        return nil
    }

    public static func validate(_ name: String, existing: [Profile], excluding: UUID? = nil) -> NameValidationError? {
        validate(name, existingNames: existing.map { ($0.id, $0.name) }, excluding: excluding)
    }

    /// "Name", "Name 2", "Name 3"… first one not taken (case-insensitive).
    public static func deduplicated(_ name: String, taken: [String]) -> String {
        let base = normalized(name).isEmpty ? "Profile" : normalized(name)
        let set = Set(taken.map { normalized($0).lowercased() })
        if !set.contains(base.lowercased()) { return base }
        var i = 2
        while true {
            let suffix = " \(i)"
            let trimmedBase = String(base.prefix(maxLength - suffix.count))
            let candidate = trimmedBase + suffix
            if !set.contains(candidate.lowercased()) { return candidate }
            i += 1
        }
    }
}
