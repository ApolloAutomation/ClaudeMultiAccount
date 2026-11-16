import AppKit
import Carbon
import CMACore
import CMASystem

/// The profile app's brain: reads its own Info.plist, launches or activates its Claude instance,
/// forwards claude:// links, draws the border and exits when Claude quits for good.
@MainActor
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private let paths = AppPaths()
    private lazy var scanner = ProcessScanner(paths: paths)
    private var config: ProfileInfoPlist?
    private var launcher: ClaudeLauncher?
    private var lock: DataDirLock?
    private var session: ClaudeSession?
    private var border: BorderOverlayController?
    private var pendingURLs: [URL] = []
    private var launching = false
    private var quitRequested = false
    private var observers: [NSObjectProtocol] = []

    private var dataDirURL: URL? { config.map { URL(filePath: $0.userDataDir, directoryHint: .isDirectory) } }
    private var idString: String { config?.profileID.uuidString ?? "" }

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        pendingURLs += Self.openURLArguments(CommandLine.arguments)
        guard let info = Bundle.main.infoDictionary, let cfg = ProfileInfoPlist(dictionary: info) else {
            fail("This profile app is misconfigured",
                 "Its settings are missing or damaged. Rebuild it from Claude Multi Account.")
            return
        }
        config = cfg
        guard let claude = ClaudeLocator(paths: paths).locate() else {
            fail("Claude Desktop isn't installed",
                 "Install Claude Desktop from claude.ai/download into Applications, then open this profile again.")
            return
        }
        launcher = ClaudeLauncher(claudeAppURL: claude.url)
        observeIPC()
        Task { await openOrActivate() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { await openOrActivate() }
        return false
    }

    /// Clicking the badged Dock tile (or picking it in ⌘-Tab) activates the agent; hand focus to Claude.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let s = session, s.isAlive else { return }
        Task { await openOrActivate() }
    }

    /// Right-click menu on the badged Dock tile.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let running = session?.isAlive == true
        let front = NSMenuItem(title: running ? "Bring to Front" : "Open", action: #selector(dockBringToFront), keyEquivalent: "")
        front.target = self
        menu.addItem(front)
        if running {
            let quit = NSMenuItem(title: "Quit \(config?.profileName ?? "Profile")", action: #selector(dockQuit), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
        }
        return menu
    }

    @objc private func dockBringToFront() { Task { await openOrActivate() } }
    @objc private func dockQuit() { quitClaude() }

    func applicationWillTerminate(_ notification: Notification) {
        border?.stop()
        lock?.unlock()
    }

    // MARK: Launch / activate

    private func openOrActivate() async {
        guard let launcher, let dir = dataDirURL, let cfg = config, !launching else { return }
        if let s = session, s.isAlive {
            _ = await launcher.activate(pid: s.pid)
            flushURLs()
            return
        }
        if let existing = scanner.instance(forDataDir: dir) {
            // Already running (e.g. agent restarted): adopt it.
            _ = try? lock(for: dir).tryLock()
            adopt(pid: existing.pid)
            _ = await launcher.activate(pid: existing.pid)
            flushURLs()
            return
        }
        let dirLock = lock(for: dir)
        guard (try? dirLock.tryLock()) == true else {
            fail("Profile is busy",
                 "Claude Multi Account is working on this profile's data (for example a backup or sync). Try again when it's done.")
            return
        }
        launching = true
        defer { launching = false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let configDir = cfg.claudeConfigDir.map { URL(filePath: $0, directoryHint: .isDirectory) }
            let urls = pendingURLs; pendingURLs = []
            let pid = try await launcher.launch(dataDir: dir, configDir: configDir, urls: urls)
            adopt(pid: pid)
        } catch {
            dirLock.unlock()
            fail("Couldn't open Claude", "\(error)")
        }
    }

    private func lock(for dir: URL) -> DataDirLock {
        if let lock { return lock }
        let l = DataDirLock(paths: paths, dataDir: dir)
        lock = l
        return l
    }

    private func adopt(pid: Int32) {
        session?.cancel()
        session = ClaudeSession(pid: pid) { [weak self] in self?.claudeExited(pid: pid) }
        // Show as a running app so the pinned badged tile gets its dot and Dock menu.
        NSApp.setActivationPolicy(.regular)
        postState()
        startBorder(pid: pid)
    }

    private func startBorder(pid: Int32) {
        border?.stop()
        guard let cfg = config else { return }
        let b = BorderOverlayController(pid: pid, style: .init(show: cfg.showBorder, color: cfg.color, width: cfg.borderWidth))
        border = b
        b.start()
    }

    private func claudeExited(pid: Int32) {
        border?.stop(); border = nil
        session = nil
        postState()
        guard !quitRequested, let launcher else { NSApp.terminate(nil); return }
        let watcher = UpdateWatcher(claudeAppURL: launcher.claudeAppURL, scanner: scanner, launcher: launcher)
        guard watcher.looksLikeUpdate() else { NSApp.terminate(nil); return }
        let others = scanner.claudeInstances()
        let regularWasRunning = others.contains { $0.kind == .regular }
        let prior = Set(others.map(\.pid))
        Task {
            if await watcher.waitForUpdate(regularWasRunning: regularWasRunning, priorPIDs: prior) {
                await openOrActivate()
                if session == nil { NSApp.terminate(nil) }
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Links

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = Self.validClaudeURL(s) else { return }
        pendingURLs.append(url)
        if session?.isAlive == true { flushURLs() }
    }

    private func flushURLs() {
        guard let pid = session?.pid, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs; pendingURLs = []
        for url in urls { try? ClaudeLauncher.sendGetURL(url, toPID: pid) }
    }

    static func validClaudeURL(_ s: String) -> URL? { LinkRouting.parse(s) }

    /// `--open-url <u>` or `--open-url=<u>`; invalid values are dropped.
    static func openURLArguments(_ args: [String]) -> [URL] {
        var out: [URL] = []
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            if a == IPC.openURLArgument, let v = it.next(), let u = validClaudeURL(v) { out.append(u) }
            else if a.hasPrefix(IPC.openURLArgument + "="), let u = validClaudeURL(String(a.dropFirst(IPC.openURLArgument.count + 1))) { out.append(u) }
        }
        return out
    }

    // MARK: IPC

    private func observeIPC() {
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: IPC.profileChanged, object: idString, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadBorderSettings() }
        })
        // quitProfile is honoured only with the per-profile secret the manager reads from Locks/ (0600).
        if let id = config?.profileID, let token = try? QuitToken.load(paths: paths, profileID: id) {
            observers.append(dnc.addObserver(forName: IPC.quitProfile, object: idString, queue: .main) { [weak self] note in
                guard QuitToken.matches(note.userInfo?[QuitToken.userInfoKey], expected: token) else { return }
                MainActor.assumeIsolated { self?.quitClaude() }
            })
        }
    }

    private func reloadBorderSettings() {
        guard let cfg = config else { return }
        let store = ProfileStore(paths: paths)
        let id = cfg.profileID
        Task {
            guard let p = try? await store.reload().first(where: { $0.id == id }) else { return }
            config?.showBorder = p.showBorder
            config?.borderWidth = p.borderWidth
            config?.color = p.color
            border?.update(style: .init(show: p.showBorder, color: p.color, width: p.borderWidth))
        }
    }

    private func quitClaude() {
        quitRequested = true
        guard let pid = session?.pid, let launcher else { NSApp.terminate(nil); return }
        Task {
            if !(await launcher.terminate(pid: pid, timeout: .seconds(15))) { quitRequested = false }
        }
    }

    private func postState() {
        DistributedNotificationCenter.default().postNotificationName(
            IPC.agentStateChanged, object: idString, userInfo: nil, deliverImmediately: true)
    }

    // MARK: Alerts

    private func fail(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        if session == nil { NSApp.terminate(nil) }
    }
}
