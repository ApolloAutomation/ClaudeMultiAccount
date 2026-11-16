import Foundation

public struct FileCopyOp: Sendable, Equatable {
    public var source: URL
    public var destination: URL
    public var isDirectory: Bool
}

public struct FileWriteOp: Sendable, Equatable {
    public var destination: URL
    public var data: Data
}

public struct SettingsImportPlan: Sendable, Equatable {
    public var addedMCPServers: [String] = []
    public var addedPreferences: [String] = []
    public var addedTopLevelKeys: [String] = []
    public var copiesDeveloperSettings = false
    public var addedExtensions: [String] = []
    public var writes: [FileWriteOp] = []
    public var copies: [FileCopyOp] = []

    public var isEmpty: Bool { writes.isEmpty && copies.isEmpty }
}

/// Regular → profile import: missing-only merge. `config.json` (auth caches) is never read, written or backed up.
public enum SettingsImportPlanner {

    static func isDenied(_ key: String) -> Bool { key.lowercased().hasPrefix("oauth") }

    static func object(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// Adds keys of `source` missing in `dest`. Returns added keys sorted.
    public static func mergeMissing(_ source: [String: Any], into dest: inout [String: Any]) -> [String] {
        var added: [String] = []
        for (k, v) in source where dest[k] == nil && !isDenied(k) {
            dest[k] = v; added.append(k)
        }
        return added.sorted()
    }

    /// claude_desktop_config.json: missing mcpServers entries, preferences entries, and top-level keys.
    public static func mergeDesktopConfig(source: [String: Any], dest: [String: Any]) -> (merged: [String: Any], servers: [String], prefs: [String], topLevel: [String]) {
        var out = dest
        var servers: [String] = [], prefs: [String] = []
        for (key, bucket) in [("mcpServers", 0), ("preferences", 1)] {
            guard let src = source[key] as? [String: Any] else { continue }
            if out[key] == nil {
                out[key] = src
                let keys = src.keys.sorted()
                if bucket == 0 { servers = keys } else { prefs = keys }
            } else if var dst = out[key] as? [String: Any] {
                let added = mergeMissing(src, into: &dst)
                out[key] = dst
                if bucket == 0 { servers = added } else { prefs = added }
            }
        }
        var rest = source
        rest["mcpServers"] = nil; rest["preferences"] = nil
        let top = mergeMissing(rest, into: &out)
        return (out, servers, prefs, top)
    }

    public static func plan(from source: ClaudeDataDir, to dest: ClaudeDataDir) throws -> SettingsImportPlan {
        var plan = SettingsImportPlan()
        let fm = FileManager.default

        if let src = object(source.desktopConfigJSON) {
            let dst = object(dest.desktopConfigJSON) ?? [:]
            if fm.fileExists(atPath: dest.desktopConfigJSON.path) && object(dest.desktopConfigJSON) == nil {
                // Unparseable destination: leave it alone.
            } else {
                let m = mergeDesktopConfig(source: src, dest: dst)
                plan.addedMCPServers = m.servers; plan.addedPreferences = m.prefs; plan.addedTopLevelKeys = m.topLevel
                if !(m.servers.isEmpty && m.prefs.isEmpty && m.topLevel.isEmpty) {
                    plan.writes.append(FileWriteOp(destination: dest.desktopConfigJSON, data: try AtomicFile.jsonData(m.merged)))
                }
            }
        }

        if fm.fileExists(atPath: source.developerSettingsJSON.path) && !fm.fileExists(atPath: dest.developerSettingsJSON.path) {
            plan.copiesDeveloperSettings = true
            plan.copies.append(FileCopyOp(source: source.developerSettingsJSON, destination: dest.developerSettingsJSON, isDirectory: false))
        }

        if let srcInst = object(source.extensionsInstallationsJSON), let srcExt = srcInst["extensions"] as? [String: Any] {
            let destExists = fm.fileExists(atPath: dest.extensionsInstallationsJSON.path)
            let dstInstOpt = object(dest.extensionsInstallationsJSON)
            if !destExists || dstInstOpt != nil {
                var dstInst = dstInstOpt ?? [:]
                var dstExt = dstInst["extensions"] as? [String: Any] ?? [:]
                for id in srcExt.keys.sorted() where dstExt[id] == nil && SafePath.isSafeComponent(id) {
                    dstExt[id] = srcExt[id]
                    plan.addedExtensions.append(id)
                    let sDir = source.extensionsDir.appending(path: id, directoryHint: .isDirectory)
                    let dDir = dest.extensionsDir.appending(path: id, directoryHint: .isDirectory)
                    if fm.fileExists(atPath: sDir.path) && !fm.fileExists(atPath: dDir.path) {
                        plan.copies.append(FileCopyOp(source: sDir, destination: dDir, isDirectory: true))
                    }
                    let sSet = source.extensionsSettingsDir.appending(path: "\(id).json")
                    let dSet = dest.extensionsSettingsDir.appending(path: "\(id).json")
                    if fm.fileExists(atPath: sSet.path) && !fm.fileExists(atPath: dSet.path) {
                        plan.copies.append(FileCopyOp(source: sSet, destination: dSet, isDirectory: false))
                    }
                }
                if !plan.addedExtensions.isEmpty {
                    dstInst["extensions"] = dstExt
                    plan.writes.append(FileWriteOp(destination: dest.extensionsInstallationsJSON, data: try AtomicFile.jsonData(dstInst)))
                }
            }
        }

        return plan
    }
}
