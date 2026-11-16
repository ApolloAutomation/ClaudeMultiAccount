import Foundation

public enum Slug {
    /// Lowercase ASCII, diacritics folded, runs of anything else → "-", trimmed. Empty → "profile".
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        var lastDash = false
        for s in folded.unicodeScalars {
            if (s >= "a" && s <= "z") || (s >= "0" && s <= "9") {
                out.unicodeScalars.append(s); lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-"); lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 40 {
            out = String(out.prefix(40))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "profile" : out
    }

    public static func terminalCommand(for name: String) -> String { "claude-\(slug(name))" }

    /// First 8 hex characters of the UUID, lowercase.
    public static func id8(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    public static func bundleIdentifier(for id: UUID) -> String { "\(AppPaths.bundleID).profile.\(id8(id))" }

    public static func appName(_ name: String) -> String { "Claude (\(name))" }

    /// First letter/digit, uppercased; "?" if none.
    public static func badgeLetter(_ name: String) -> String {
        guard let c = name.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(c).uppercased()
    }
}
