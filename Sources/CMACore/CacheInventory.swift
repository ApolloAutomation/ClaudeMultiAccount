import Foundation

public enum CacheInventory {
    /// Directories inside a data dir that "Clear Cache" may remove.
    public static let cacheDirNames: [String] = [
        "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache",
        "GPUPersistentCache", "ShaderCache", "Shared Dictionary", "Extensions Update Cache",
    ]
    /// Extra top-level names never put in a backup.
    public static let backupOnlyExcludes: [String] = [
        "Crashpad", "sentry", "vm_bundles", "claude-code-vm", "claude-code", "claude-code-spare",
    ]

    public static func isCacheDir(_ name: String) -> Bool { cacheDirNames.contains(name) }

    /// Top-level entry names excluded from backups (cache dirs, crash/VM data, Singleton* lock files).
    public static func isBackupExcluded(_ name: String) -> Bool {
        isCacheDir(name) || backupOnlyExcludes.contains(name) || name.hasPrefix("Singleton")
    }

    public static func cacheDirs(in dataDir: URL) -> [URL] {
        cacheDirNames.map { dataDir.appending(path: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Allocated size in bytes, recursive, without following symlinks.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isRegularFile == true { return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    public static func cacheSize(in dataDir: URL) -> Int64 { cacheDirs(in: dataDir).reduce(0) { $0 + size(of: $1) } }
}
