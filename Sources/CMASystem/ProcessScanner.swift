import AppKit
import CMACore
import Foundation

/// Finds running Claude Desktop main processes and classifies them by `--user-data-dir`.
/// Only main processes (NSWorkspace running applications) are considered; helpers are ignored.
public struct ProcessScanner: ProcessScanning {
    public let paths: AppPaths
    /// Injected for tests: returns argv for a pid. Defaults to `KERN_PROCARGS2`.
    private let argumentsForPID: @Sendable (Int32) -> [String]?

    public init(paths: AppPaths = AppPaths(),
                argumentsForPID: @escaping @Sendable (Int32) -> [String]? = { ProcArgs.fetch(pid: $0)?.arguments }) {
        self.paths = paths
        self.argumentsForPID = argumentsForPID
    }

    public func claudeInstances() -> [ClaudeInstance] {
        let ws = NSWorkspace.shared
        let front = ws.frontmostApplication?.processIdentifier
        return ws.runningApplications
            .filter { $0.bundleIdentifier == AppPaths.claudeBundleID && !$0.isTerminated }
            .compactMap { app -> ClaudeInstance? in
                let pid = app.processIdentifier
                guard pid > 0 else { return nil }
                let (kind, dir) = classify(arguments: argumentsForPID(pid))
                return ClaudeInstance(pid: pid, kind: kind, dataDir: dir,
                                      isFrontmost: pid == front, launchDate: app.launchDate)
            }
            .sorted { $0.pid < $1.pid }
    }

    public func instance(forDataDir dir: URL) -> ClaudeInstance? {
        let want = ProcArgs.normalize(dir.path)
        return claudeInstances().first { ProcArgs.normalize($0.dataDir.path) == want }
    }

    /// Pure classification. nil argv (sysctl refused / process gone) → foreign with empty dir: unknown, never touched.
    public func classify(arguments: [String]?) -> (InstanceKind, URL) {
        guard let arguments else { return (.foreign(dataDir: ""), URL(filePath: "/dev/null")) }
        guard let raw = ProcArgs.userDataDir(from: arguments) else { return (.regular, paths.regularClaudeDir) }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(filePath: expanded, directoryHint: .isDirectory).standardizedFileURL
        let norm = ProcArgs.normalize(expanded)
        if norm == ProcArgs.normalize(paths.regularClaudeDir.path) { return (.regular, paths.regularClaudeDir) }
        let parent = (norm as NSString).deletingLastPathComponent
        if parent == ProcArgs.normalize(paths.profilesDir.path),
           let id = UUID(uuidString: (norm as NSString).lastPathComponent) {
            return (.profile(id), url)
        }
        return (.foreign(dataDir: expanded), url)
    }
}
