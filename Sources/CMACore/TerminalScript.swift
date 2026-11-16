import Foundation

/// `claude-<slug>` shell script that runs Claude Code with a per-profile CLAUDE_CONFIG_DIR.
public enum TerminalScript {
    public static let markerPrefix = "# cma-profile-id: "
    public static let seededItems = ["CLAUDE.md", "settings.json", "skills", "projects", "agents", "plugins"]

    public static func candidates(home: URL) -> [String] {
        [home.appending(path: ".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
         home.appending(path: ".claude/local/claude").path, home.appending(path: ".npm-global/bin/claude").path]
    }

    /// POSIX single-quote quoting: `'` → `'\''`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func marker(_ id: UUID) -> String { markerPrefix + id.uuidString }

    public static func render(profileID: UUID, profileName: String, configDir: URL, home: URL) -> String {
        let safeName = profileName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        let cmd = Slug.terminalCommand(for: profileName)
        let list = candidates(home: home).map(shellQuote).joined(separator: " ")
        return """
        #!/bin/sh
        # Created by Claude Multi Account for profile: \(safeName)
        \(marker(profileID))
        export CLAUDE_CONFIG_DIR=\(shellQuote(configDir.path))
        for c in \(list); do
          if [ -x "$c" ]; then exec "$c" "$@"; fi
        done
        echo \(shellQuote("\(cmd): Claude Code (claude) not found. Install it, then try again.")) >&2
        exit 127

        """
    }

    public static func render(profile: Profile, paths: AppPaths) -> String {
        render(profileID: profile.id, profileName: profile.name, configDir: paths.cliConfigDir(for: profile.id), home: paths.home)
    }

    /// True if the script carries our marker (for `profileID` when given). Files without it are never overwritten.
    public static func isOwned(_ contents: String, profileID: UUID? = nil) -> Bool {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).prefix(10) where line.hasPrefix(markerPrefix) {
            let id = UUID(uuidString: String(line.dropFirst(markerPrefix.count)).trimmingCharacters(in: .whitespaces))
            guard let id else { continue }
            return profileID == nil || id == profileID
        }
        return false
    }

    public enum InstallCheck: Equatable, Sendable { case free, ownedBySameProfile, ownedByOtherProfile, foreign }

    /// Decide whether `url` may be (over)written for `profileID`.
    public static func check(_ url: URL, profileID: UUID) -> InstallCheck {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { return .foreign }
        guard fm.fileExists(atPath: url.path) else { return .free }
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return .foreign }
        if isOwned(s, profileID: profileID) { return .ownedBySameProfile }
        if isOwned(s) { return .ownedByOtherProfile }
        return .foreign
    }

    public static func installURL(binDir: URL, profileName: String) -> URL {
        binDir.appending(path: Slug.terminalCommand(for: profileName))
    }

    /// Symlinks to create inside the profile's CLI config dir: link → target in ~/.claude.
    public static func seedLinks(profileID: UUID, paths: AppPaths) -> [(link: URL, target: URL)] {
        let dir = paths.cliConfigDir(for: profileID)
        return seededItems.map { (dir.appending(path: $0), paths.claudeConfigDir.appending(path: $0)) }
    }
}
