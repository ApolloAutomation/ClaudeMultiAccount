import CMACore
import Foundation

public enum BackupError: Error, Equatable {
    case dataDirMissing(String)
    case invalidArchive(String)
    case unsupportedVersion(Int)
    case unsafeEntry(String)
    case toolFailed(String)
}

public struct BackupInspection: Sendable, Equatable {
    public let manifest: BackupManifest
    public let dataRoot: String
}

/// Profile backups as zip: `manifest.json` + `<UUID>/…` (caches and crash/VM data excluded).
/// Callers must ensure the profile is quit (and locked) around export/restore.
public struct BackupArchiver: Sendable {
    public let paths: AppPaths
    public let zip: URL
    public let unzip: URL
    public let appVersion: String

    public init(paths: AppPaths, zip: URL = URL(fileURLWithPath: "/usr/bin/zip"),
                unzip: URL = URL(fileURLWithPath: "/usr/bin/unzip"), appVersion: String = "1.0") {
        self.paths = paths; self.zip = zip; self.unzip = unzip; self.appVersion = appVersion
    }

    public static func suggestedFileName(for profile: Profile, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "Claude (\(profile.name)) Backup \(f.string(from: date)).zip"
    }

    // MARK: Export

    @discardableResult
    public func export(_ profile: Profile, to destination: URL) async throws -> URL {
        let fm = FileManager.default
        let dataDir = paths.dataDir(for: profile.id)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dataDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw BackupError.dataDirMissing(dataDir.path)
        }
        let stage = paths.buildDir.appending(path: "backup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { if (try? SafePath.require(stage, within: [paths.buildDir])) != nil { try? fm.removeItem(at: stage) } }
        let out = stage.appending(path: "backup.zip")
        let manifest = stage.appending(path: BackupManifest.fileName)
        try AtomicFile.write(BackupManifest(profile: profile, appVersion: appVersion).encoded(), to: manifest)

        let root = profile.id.uuidString
        // Bare directory entry for the root (non-recursive), so an empty profile still has a data root.
        try await tool(zip, ["-q", out.path, root], cwd: paths.profilesDir)
        let names = ((try? fm.contentsOfDirectory(atPath: dataDir.path)) ?? []).sorted()
            .filter { !CacheInventory.isBackupExcluded($0) }
        if !names.isEmpty {
            try await tool(zip, ["-q", "-r", "-y", out.path] + names.map { "\(root)/\($0)" }, cwd: paths.profilesDir)
        }
        try await tool(zip, ["-q", "-j", out.path, manifest.path], cwd: stage)
        _ = try await inspect(out) // self-check
        // Holds cookies and auth caches: owner-only before it ever reaches the chosen folder.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: out, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: out, to: destination)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    // MARK: Inspect / restore

    func listEntries(_ archive: URL) throws -> [String] {
        let r = try Subprocess.runSync(unzip, ["-Z1", archive.path])
        guard r.succeeded else { throw BackupError.invalidArchive(r.stderrString) }
        return r.stdoutString.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Entry names that are symlinks (from the long `zipinfo` listing, same order as `-Z1`).
    func symlinkEntries(_ archive: URL, names: [String]) throws -> [String] {
        let r = try Subprocess.runSync(unzip, ["-Z", archive.path])
        guard r.succeeded else { throw BackupError.invalidArchive(r.stderrString) }
        let lines = r.stdoutString.split(separator: "\n").map(String.init).filter {
            guard let c = $0.first, "-dlbcps?".contains(c), $0.count > 10 else { return false }
            let perm = $0.prefix(10)
            return perm.allSatisfy { "-rwxdlbcpsStT?".contains($0) }
        }
        guard lines.count == names.count else { throw BackupError.invalidArchive("listing mismatch") }
        return Swift.zip(lines, names).compactMap { line, name in line.hasPrefix("l") ? name : nil }
    }

    /// Validates entry names (zip-slip), symlink placement and the manifest without extracting data.
    public func inspect(_ archive: URL) async throws -> BackupInspection {
        let names = try listEntries(archive)
        let root: String
        do { root = try BackupEntryValidator.validate(names) } catch {
            throw BackupError.unsafeEntry(String(describing: error))
        }
        let links = try symlinkEntries(archive, names: names)
        for l in links {
            let base = l.hasSuffix("/") ? String(l.dropLast()) : l
            if base == root || names.contains(where: { $0.hasPrefix(base + "/") }) {
                throw BackupError.unsafeEntry(l)
            }
        }
        if links.contains(BackupManifest.fileName) { throw BackupError.unsafeEntry(BackupManifest.fileName) }
        let r = try await Subprocess.run(unzip, ["-p", archive.path, BackupManifest.fileName])
        guard r.succeeded else { throw BackupError.invalidArchive("manifest unreadable") }
        let manifest: BackupManifest
        do { manifest = try BackupManifest.decode(r.stdout) } catch { throw BackupError.invalidArchive("manifest damaged") }
        guard manifest.isSupported else { throw BackupError.unsupportedVersion(manifest.formatVersion) }
        return BackupInspection(manifest: manifest, dataRoot: root)
    }

    /// Extracts into `Build/restore-*`, then moves the data to `Profiles/<new UUID>`. Returns the new profile
    /// (fresh id, deduplicated name); the caller adds it to the store and builds its app.
    public func restore(from archive: URL, existingNames: [String], newID: UUID = UUID()) async throws -> Profile {
        let fm = FileManager.default
        let info = try await inspect(archive)
        let stage = paths.buildDir.appending(path: "restore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { if (try? SafePath.require(stage, within: [paths.buildDir])) != nil { try? fm.removeItem(at: stage) } }
        try await tool(unzip, ["-q", "-o", archive.path, "-d", stage.path], cwd: stage)

        let extracted = stage.appending(path: info.dataRoot, directoryHint: .isDirectory)
        try Self.checkSymlinksStayInside(extracted)
        let manifestData = try Data(contentsOf: stage.appending(path: BackupManifest.fileName))
        let manifest = try BackupManifest.decode(manifestData)
        guard manifest.isSupported else { throw BackupError.unsupportedVersion(manifest.formatVersion) }

        let profile = manifest.restoredProfile(existingNames: existingNames, id: newID)
        let dest = paths.dataDir(for: profile.id)
        guard !fm.fileExists(atPath: dest.path) else { throw BackupError.invalidArchive("destination exists") }
        try fm.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        try fm.moveItem(at: extracted, to: dest)
        return profile
    }

    static func checkSymlinksStayInside(_ root: URL) throws {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return }
        for case let rel as String in e {
            let u = root.appending(path: rel)
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: u.path) else { continue }
            let target = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : u.deletingLastPathComponent().appending(path: dest)
            let p = target.standardizedFileURL.path
            let rootStd = root.standardizedFileURL.path
            guard p.hasPrefix(rootStd + "/") || p.hasPrefix(base + "/") else { throw BackupError.unsafeEntry(rel) }
        }
    }

    @discardableResult
    func tool(_ exe: URL, _ args: [String], cwd: URL) async throws -> SubprocessResult {
        let r = try await Subprocess.run(exe, args, currentDirectory: cwd)
        if r.succeeded { return r }
        throw BackupError.toolFailed("\(exe.lastPathComponent) \(r.status): \(r.stderrString)")
    }
}
