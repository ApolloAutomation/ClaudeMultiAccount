import AppKit
import Carbon
import CMACore
import Foundation

public enum ClaudeLaunchError: Error, Equatable {
    case claudeNotFound
    case launchFailed(String)
    case urlForwardFailed(String)
    case invalidURL
}

/// Launches / activates / terminates Claude Desktop instances. One instance per data dir.
public struct ClaudeLauncher: ClaudeLaunching {
    public let claudeAppURL: URL

    public init(claudeAppURL: URL) { self.claudeAppURL = claudeAppURL }

    public init?(locator: ClaudeLocator = ClaudeLocator()) {
        guard let inst = locator.locate() else { return nil }
        claudeAppURL = inst.url
    }

    /// New instance with `--user-data-dir=<dir>`; `CLAUDE_CONFIG_DIR` only when given. URLs are forwarded
    /// with a GURL Apple Event to the new pid once it has finished launching.
    public func launch(dataDir: URL, configDir: URL?, urls: [URL]) async throws -> Int32 {
        let pid = try await Self.open(app: claudeAppURL, dataDir: dataDir.path, configDir: configDir?.path)
        if !urls.isEmpty {
            await Self.waitUntilFinishedLaunching(pid: pid, timeout: .seconds(30))
            try? await Task.sleep(for: .milliseconds(1500))
            for url in urls { try Self.sendGetURL(url, toPID: pid) }
        }
        return pid
    }

    @MainActor
    private static func open(app: URL, dataDir: String, configDir: String?) async throws -> Int32 {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.arguments = ["\(ProcArgs.userDataDirFlag)=\(dataDir)"]
        cfg.addsToRecentItems = false
        cfg.activates = true
        if let configDir, !configDir.isEmpty { cfg.environment = ["CLAUDE_CONFIG_DIR": configDir] }
        do {
            let running = try await NSWorkspace.shared.openApplication(at: app, configuration: cfg)
            return running.processIdentifier
        } catch {
            throw ClaudeLaunchError.launchFailed(error.localizedDescription)
        }
    }

    public static func waitUntilFinishedLaunching(pid: Int32, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
            if app.isFinishedLaunching { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    public func activate(pid: Int32) async -> Bool { await Self.activateNow(pid: pid) }

    @MainActor
    public static func activateNow(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        if app.isHidden { app.unhide() }
        if app.activate(options: [.activateAllWindows]) { return true }
        return activateViaSystemEvents(pid: pid)
    }

    /// Fallback: System Events `set frontmost` by unix id. Constant script; pid passed as a handler parameter.
    @MainActor
    static func activateViaSystemEvents(pid: Int32) -> Bool {
        let source = """
        on cma_activate(p)
            tell application "System Events" to set frontmost of (first process whose unix id is p) to true
        end cma_activate
        """
        guard let script = NSAppleScript(source: source) else { return false }
        let params = NSAppleEventDescriptor.list()
        params.insert(NSAppleEventDescriptor(int32: pid), at: 0)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "cma_activate"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(params, forKeyword: keyDirectObject)
        var err: NSDictionary?
        script.executeAppleEvent(event, error: &err)
        return err == nil
    }

    /// Graceful quit; waits up to `timeout` for exit.
    public func terminate(pid: Int32, timeout: Duration) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
        if app.isTerminated { return true }
        _ = app.terminate()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if app.isTerminated || kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return app.isTerminated
    }

    /// Sends kAEGetURL ('GURL') with the URL string to a specific pid.
    public static func sendGetURL(_ url: URL, toPID pid: Int32) throws {
        guard LinkRouting.isValid(url) else { throw ClaudeLaunchError.invalidURL }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: keyDirectObject)
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
        } catch {
            throw ClaudeLaunchError.urlForwardFailed(error.localizedDescription)
        }
    }
}
