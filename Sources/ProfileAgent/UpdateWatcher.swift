import CMACore
import CMASystem
import Darwin
import Foundation

/// Detects Claude quitting to self-update (Squirrel/ShipIt) and waits for the new install.
@MainActor
struct UpdateWatcher {
    let claudeAppURL: URL
    let scanner: ProcessScanner
    let launcher: ClaudeLauncher

    var shipItCache: URL {
        scanner.paths.home.appending(path: "Library/Caches/\(AppPaths.claudeBundleID).ShipIt", directoryHint: .isDirectory)
    }

    /// Call right when our Claude exited.
    func looksLikeUpdate(now: Date = Date()) -> Bool {
        if Self.isShipItRunning() { return true }
        guard let changed = Self.latestModification(of: shipItCache) else { return false }
        return now.timeIntervalSince(changed) < 60
    }

    /// Waits for ShipIt to finish and the new bundle to be readable, then watches 20 s for a relaunched
    /// flagless (regular) Claude and terminates it unless regular Claude was already running.
    /// Returns true when the install looks ready for relaunching on the profile.
    func waitForUpdate(regularWasRunning: Bool, priorPIDs: Set<Int32>) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            if !Self.isShipItRunning() && ClaudeLocator.isClaude(claudeAppURL) { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard ClaudeLocator.isClaude(claudeAppURL) else { return false }
        let watchEnd = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < watchEnd {
            if let stray = scanner.claudeInstances().first(where: { $0.kind == .regular && !priorPIDs.contains($0.pid) }) {
                if !regularWasRunning { _ = await launcher.terminate(pid: stray.pid, timeout: .seconds(10)) }
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return true
    }

    static func isShipItRunning() -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return false }
        var name = [UInt8](repeating: 0, count: 256)
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = name.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            if len > 0, String(decoding: name.prefix(Int(len)), as: UTF8.self) == "ShipIt" { return true }
        }
        return false
    }

    static func latestModification(of dir: URL) -> Date? {
        let fm = FileManager.default
        var dates: [Date] = []
        if let d = (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date { dates.append(d) }
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in items {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { dates.append(d) }
        }
        return dates.max()
    }
}
