import Foundation

/// Which Claude Desktop instance a running main process belongs to.
public enum InstanceKind: Sendable, Equatable, Hashable {
    case regular
    case profile(UUID)
    /// Launched with a --user-data-dir we don't own (e.g. another tool). Read-only to us.
    case foreign(dataDir: String)
}

public struct ClaudeInstance: Sendable, Identifiable, Equatable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let kind: InstanceKind
    public let dataDir: URL
    public let isFrontmost: Bool
    public let launchDate: Date?
    public init(pid: Int32, kind: InstanceKind, dataDir: URL, isFrontmost: Bool, launchDate: Date? = nil) {
        self.pid = pid; self.kind = kind; self.dataDir = dataDir; self.isFrontmost = isFrontmost; self.launchDate = launchDate
    }
}

public protocol ProcessScanning: Sendable {
    func claudeInstances() -> [ClaudeInstance]
    func instance(forDataDir dir: URL) -> ClaudeInstance?
}

public protocol ClaudeLaunching: Sendable {
    func launch(dataDir: URL, configDir: URL?, urls: [URL]) async throws -> Int32
    func activate(pid: Int32) async -> Bool
    func terminate(pid: Int32, timeout: Duration) async -> Bool
}

public protocol DockEditing: Sendable {
    func isInDock(bundleID: String) -> Bool
    func add(appURL: URL, label: String, bundleID: String) throws
    func remove(bundleID: String) throws
}
