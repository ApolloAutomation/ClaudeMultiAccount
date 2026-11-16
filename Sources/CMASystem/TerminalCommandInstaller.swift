import CMACore
import Foundation

public enum TerminalCommandError: Error, Equatable {
    case foreignFileExists(String)
    case ownedByOtherProfile(String)
    case noWritableBinDir
}

/// Installs `claude-<slug>` scripts and seeds the per-profile CLAUDE_CONFIG_DIR.
public struct TerminalCommandInstaller: Sendable {
    public let paths: AppPaths
    /// Preference order. Default: `~/.local/bin`, then `/usr/local/bin` if writable.
    public let binDirs: [URL]

    public init(paths: AppPaths, binDirs: [URL]? = nil) {
        self.paths = paths
        self.binDirs = binDirs ?? [paths.localBinDir, URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)]
    }

    /// Where an existing script for this profile lives (any bin dir, current name).
    public func installedURL(_ profile: Profile) -> URL? {
        for dir in binDirs {
            let u = TerminalScript.installURL(binDir: dir, profileName: profile.name)
            if TerminalScript.check(u, profileID: profile.id) == .ownedBySameProfile { return u }
        }
        return nil
    }

    /// Our scripts for this profile under any name (e.g. left from before a rename).
    public func ownedScripts(_ profile: Profile) -> [URL] {
        binDirs.flatMap { dir -> [URL] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { $0.hasPrefix("claude-") }.map { dir.appending(path: $0) }
                .filter { TerminalScript.check($0, profileID: profile.id) == .ownedBySameProfile }
        }
    }

    func chooseBinDir() throws -> URL {
        let fm = FileManager.default
        for (i, dir) in binDirs.enumerated() {
            if i == 0 { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            if fm.isWritableFile(atPath: dir.path) { return dir }
        }
        throw TerminalCommandError.noWritableBinDir
    }

    @discardableResult
    public func install(_ profile: Profile) throws -> URL {
        try seedCLIDir(for: profile)
        if let existing = installedURL(profile) {
            try write(profile, to: existing)
            return existing
        }
        for dir in binDirs {
            let u = TerminalScript.installURL(binDir: dir, profileName: profile.name)
            switch TerminalScript.check(u, profileID: profile.id) {
            case .foreign: throw TerminalCommandError.foreignFileExists(u.path)
            case .ownedByOtherProfile: throw TerminalCommandError.ownedByOtherProfile(u.path)
            default: continue
            }
        }
        let dest = TerminalScript.installURL(binDir: try chooseBinDir(), profileName: profile.name)
        try write(profile, to: dest)
        // Drop stale scripts from a previous name.
        for old in ownedScripts(profile) where old.standardizedFileURL != dest.standardizedFileURL {
            try? removeOwned(old, profileID: profile.id)
        }
        return dest
    }

    func write(_ profile: Profile, to url: URL) throws {
        try AtomicFile.write(TerminalScript.render(profile: profile, paths: paths), to: url, permissions: 0o755)
    }

    /// Deletes one of our scripts: must sit inside a configured bin dir and still carry this profile's marker.
    func removeOwned(_ url: URL, profileID: UUID) throws {
        try SafePath.require(url, within: binDirs)
        guard TerminalScript.check(url, profileID: profileID) == .ownedBySameProfile else {
            throw TerminalCommandError.foreignFileExists(url.path)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Removes every script of ours for this profile. Foreign files are never touched.
    public func uninstall(_ profile: Profile) throws {
        for u in ownedScripts(profile) { try removeOwned(u, profileID: profile.id) }
    }

    /// Creates `CLI/<UUID>/` with symlinks to the shared `~/.claude` items that exist. Existing entries are kept.
    public func seedCLIDir(for profile: Profile) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.cliConfigDir(for: profile.id), withIntermediateDirectories: true)
        for (link, target) in TerminalScript.seedLinks(profileID: profile.id, paths: paths) {
            var st = stat()
            if lstat(link.path, &st) == 0 { continue }
            guard fm.fileExists(atPath: target.path) else { continue }
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        }
    }
}
