import CMACore
import Foundation

public struct SettingsImportResult: Sendable, Equatable {
    public var written: [URL] = []
    public var copied: [URL] = []
    public var backups: [URL] = []
    public var themeApplied = false
}

/// Executes a `SettingsImportPlan` into a profile data dir. Missing-only; replaced files are backed up first.
/// The profile must be quit and locked by the caller.
public struct SettingsImportExecutor: Sendable {
    public let paths: AppPaths
    public let backupRoot: URL

    public init(paths: AppPaths, backupRoot: URL? = nil) {
        self.paths = paths
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd-HHmmss"
        self.backupRoot = backupRoot ?? paths.backupsDir.appending(path: "import/\(f.string(from: Date()))", directoryHint: .isDirectory)
    }

    public func execute(_ plan: SettingsImportPlan, into dest: ClaudeDataDir) throws -> SettingsImportResult {
        let fm = FileManager.default
        var r = SettingsImportResult()
        let roots = [dest.url]
        try SafePath.require(dest.url, within: [paths.profilesDir])

        for w in plan.writes {
            try SafePath.require(w.destination, within: roots)
            guard (try? JSONSerialization.jsonObject(with: w.data)) != nil else { throw AtomicFileError.notJSONObject }
            var mode: mode_t = 0o644
            if fm.fileExists(atPath: w.destination.path) {
                r.backups.append(try backup(w.destination, dataDir: dest.url))
                if let p = (try? fm.attributesOfItem(atPath: w.destination.path))?[.posixPermissions] as? NSNumber { mode = mode_t(p.uint16Value) }
            }
            try AtomicFile.write(w.data, to: w.destination, permissions: mode)
            r.written.append(w.destination)
        }
        for c in plan.copies {
            try SafePath.require(c.destination, within: roots)
            guard !fm.fileExists(atPath: c.destination.path) else { continue }
            try fm.createDirectory(at: c.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: c.source, to: c.destination)
            r.copied.append(c.destination)
        }
        if !plan.themeKeys.isEmpty {
            let existing = try? Data(contentsOf: dest.configJSON)
            if let data = SettingsImportPlanner.applyTheme(plan.themeKeys, toConfig: existing) {
                var mode: mode_t = 0o600
                if existing != nil {
                    r.backups.append(try backup(dest.configJSON, dataDir: dest.url))
                    if let p = (try? fm.attributesOfItem(atPath: dest.configJSON.path))?[.posixPermissions] as? NSNumber { mode = mode_t(p.uint16Value) }
                }
                try AtomicFile.write(data, to: dest.configJSON, permissions: mode)
                r.themeApplied = true
            }
        }
        return r
    }

    func backup(_ file: URL, dataDir: URL) throws -> URL {
        let fm = FileManager.default
        let rel = file.path.hasPrefix(dataDir.path + "/") ? String(file.path.dropFirst(dataDir.path.count + 1)) : file.lastPathComponent
        var target = backupRoot.appending(path: "\(dataDir.lastPathComponent)/\(rel)")
        var n = 2
        while fm.fileExists(atPath: target.path) { target = target.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).\(n)"); n += 1 }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: file, to: target)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }
}
