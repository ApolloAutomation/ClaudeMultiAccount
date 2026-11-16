import AppKit
import CMACore
import CMASystem
import os

/// Production `ProfileServices`: CMACore logic + CMASystem side effects against the real user folders.
/// Main-actor bound; slow file work hops off the main thread with `offMain`.
@MainActor
final class LiveProfileServices: ProfileServices {
    let paths: AppPaths
    let linkRequests: AsyncStream<LinkRequest>

    private let log = Logger(subsystem: AppPaths.bundleID, category: "services")
    private let store: ProfileStore
    private let state: RuntimeStateStore
    private let scanner: ProcessScanner
    private let journal: OperationJournal
    private let dock = DockEditor()
    private let desktop: DesktopShortcut
    private let terminal: TerminalCommandInstaller
    private let appVersion: String
    private var linkContinuation: AsyncStream<LinkRequest>.Continuation?

    private var profiles: [Profile] = []
    private var instances: [ClaudeInstance] = []
    private var settings: AppSettings
    private var lastActiveDates: [ClaudeTarget: Date] = [:]
    private var lastMarked: [ClaudeTarget: Date] = [:]
    private var accountCache: [ClaudeTarget: (value: String?, at: Date)] = [:]
    private var claudeInfo: (value: ClaudeInstallation?, at: Date)?
    private var importPlans: [UUID: SettingsImportPlan] = [:]
    private var syncPlans: [UUID: (preview: SyncPreview, plan: SessionSyncPlan)] = [:]
    private var linkRegistration: LinkHandlerRegistration?
    private var musicPause: MusicPauseCoordinator?
    private var started = false

    /// `state.json` has no slot for regular Claude; its last-active date lives under this reserved key.
    private static let regularKey = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        store = ProfileStore(paths: paths)
        state = RuntimeStateStore(paths: paths)
        scanner = ProcessScanner(paths: paths)
        journal = OperationJournal(paths: paths)
        desktop = DesktopShortcut(paths: paths)
        terminal = TerminalCommandInstaller(paths: paths)
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

        let runtime = RuntimeStateStore.load(url: paths.stateJSON)
        settings = Self.uiSettings(runtime.settings)
        settings.launchAtLogin = LoginItem.state == .enabled
        for (key, date) in runtime.lastActiveAt {
            guard let id = UUID(uuidString: key) else { continue }
            lastActiveDates[id == Self.regularKey ? .regular : .profile(id)] = date
        }

        var continuation: AsyncStream<LinkRequest>.Continuation?
        linkRequests = AsyncStream { continuation = $0 }
        linkContinuation = continuation
    }

    // MARK: Launch-time work

    func start() {
        guard !started else { return }
        started = true
        LinkInbox.shared.attach { [weak self] url in self?.handleIncomingLink(url) }
        Task {
            await recoverJournal()
            _ = try? await loadProfiles()
            registerAllHotKeys()
            await applyRuntimeSettings(previous: nil)
            await rebuildStaleProfiles()
        }
    }

    /// Finishes multi-step operations that were interrupted (crash, power loss).
    private func recoverJournal() async {
        let mover = makeMover()
        do {
            for outcome in try mover.recover() {
                if case let .deferred(_, reason) = outcome {
                    log.notice("interrupted move left pending: \(reason, privacy: .public)")
                    continue
                }
                guard case let .needsProfile(entryID, profileID, _) = outcome else { continue }
                if (try? await store.profile(id: profileID)) == nil {
                    let names = ((try? await store.all()) ?? []).map(\.name)
                    let profile = Profile(id: profileID, name: NameValidator.deduplicated("Moved Claude", taken: names), color: .orange)
                    try await store.add(profile)
                    _ = try? await builder().build(profile)
                }
                try journal.complete(entryID)
                log.notice("recovered an interrupted move into profile \(profileID.uuidString, privacy: .public)")
            }
        } catch {
            log.error("move recovery failed: \(error.localizedDescription, privacy: .public)")
        }
        for entry in journal.pending() where entry.kind != .moveRegularClaude {
            let id = entry.payload["profileID"].flatMap(UUID.init(uuidString:))
            switch entry.kind {
            case .restoreBackup:
                if let id, FileManager.default.fileExists(atPath: paths.dataDir(for: id).path),
                   (try? await store.profile(id: id)) == nil {
                    let names = ((try? await store.all()) ?? []).map(\.name)
                    let name = NameValidator.deduplicated(entry.payload["name"] ?? "Restored", taken: names)
                    let color = entry.payload["color"].flatMap(ProfileColor.init(rawValue:)) ?? .orange
                    let profile = Profile(id: id, name: name, color: color)
                    if (try? await store.add(profile)) != nil { _ = try? await builder().build(profile) }
                }
            case .deleteProfile:
                if let id, !FileManager.default.fileExists(atPath: paths.dataDir(for: id).path) {
                    let b = BundleBuilder(paths: paths, agentBinary: URL(filePath: "/dev/null"))
                    for app in b.installedApps(profileID: id) { try? await b.remove(appURL: app) }
                    try? await store.remove(id: id)
                    try? await state.forget(id)
                }
            case .renameProfile:
                // Rebuild under the current name, then drop the app left under the old name so it can't
                // recreate the profile's data folder after a delete.
                if let id, let profile = try? await store.profile(id: id), let builder = try? builder() {
                    let old = entry.payload["oldName"].map { paths.appURL(forName: $0) }
                    if (try? await builder.build(profile, previousAppURL: old)) != nil {
                        try? await builder.removeStaleApps(for: profile)
                    } else {
                        continue // keep the journal entry; retry at the next launch
                    }
                }
            case .sessionSync, .moveRegularClaude:
                break // Each session file was written atomically with a backup; nothing to finish.
            }
            try? journal.complete(entry.id)
        }
    }

    /// Profile apps built by an older agent/builder (or with outdated settings) are rebuilt while not running.
    private func rebuildStaleProfiles() async {
        guard let builder = try? builder() else { return }
        let running = scanner.claudeInstances()
        for profile in profiles where !running.contains(where: { $0.kind == .profile(profile.id) }) {
            guard (try? builder.needsRebuild(profile)) == true else { continue }
            do {
                try await builder.build(profile)
                log.info("rebuilt stale app for \(profile.id.uuidString, privacy: .public)")
            } catch {
                log.error("stale rebuild failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Profiles

    func loadProfiles() async throws -> [Profile] {
        profiles = try await store.reload()
        return profiles
    }

    func validateName(_ name: String, excluding id: UUID?) -> String? {
        NameValidator.validate(NameValidator.normalized(name), existing: profiles, excluding: id)?.message
    }

    func createProfile(name: String, color: ProfileColor, source: NewProfileSource) async throws -> Profile {
        try await friendly {
            _ = try await loadProfiles()
            let name = NameValidator.normalized(name)
            if let error = validateName(name, excluding: nil) { throw ServiceError(error) }
            let builder = try builder()
            let profile: Profile
            switch source {
            case .empty:
                profile = Profile(name: name, color: color)
                try FileManager.default.createDirectory(at: paths.dataDir(for: profile.id), withIntermediateDirectories: true)
                try await store.add(profile)
            case .moveRegular:
                profile = Profile(name: name, color: color)
                let mover = makeMover()
                try await withQuit([.regular], what: "move it into a profile") { [store] in
                    let entry = try mover.move(to: profile.id)
                    try await store.add(profile)
                    try mover.complete(entry)
                }
            case .restore(let archive):
                let id = UUID()
                let entry = try journal.begin(.restoreBackup, payload: ["profileID": id.uuidString, "name": name, "color": color.rawValue])
                let archiver = BackupArchiver(paths: paths, appVersion: appVersion)
                var restored = try await archiver.restore(from: archive, existingNames: profiles.map(\.name), newID: id)
                restored.name = name
                restored.color = color
                try await store.add(restored)
                try journal.complete(entry.id)
                profile = restored
            }
            _ = try await loadProfiles()
            do {
                try await builder.build(profile)
            } catch {
                throw ServiceError("\(profile.name) was created, but its app couldn't be built (\(Self.message(error))). Use Rebuild App to try again.")
            }
            return profile
        }
    }

    func updateProfile(_ profile: Profile) async throws {
        try await friendly {
            guard let old = try await store.profile(id: profile.id) else { throw ServiceError("That profile no longer exists.") }
            var new = profile
            new.name = NameValidator.normalized(profile.name)
            let nameChanged = new.name != old.name
            let colorChanged = new.color != old.color
            if nameChanged, let error = validateName(new.name, excluding: new.id) { throw ServiceError(error) }
            let running = isRunningNow(.profile(new.id))
            if running && (nameChanged || colorChanged) {
                throw ServiceError("Quit \(old.name) first, then change its name or color.")
            }
            let entry = nameChanged
                ? try journal.begin(.renameProfile, payload: ["profileID": new.id.uuidString, "oldName": old.name]) : nil
            try await store.update(new)
            _ = try await loadProfiles()

            let settingsChanged = new.showBorder != old.showBorder || new.borderWidth != old.borderWidth
                || new.claudeConfigDir != old.claudeConfigDir
            if nameChanged || colorChanged || (settingsChanged && !running) {
                try await builder().build(new, previousAppURL: nameChanged ? appURL(for: old) : nil)
            }
            if nameChanged { try await applyRenameFixups(old: old, new: new) }
            if let entry { try journal.complete(entry.id) }
        }
    }

    /// After a rename the app moved: point the Dock tile, Desktop alias and terminal command at the new name.
    private func applyRenameFixups(old: Profile, new: Profile) async throws {
        let newURL = appURL(for: new)
        if dock.isInDock(bundleID: new.bundleIdentifier) {
            try dock.remove(bundleID: new.bundleIdentifier)
            try dock.add(appURL: newURL, label: Slug.appName(new.name), bundleID: new.bundleIdentifier)
            try? await dock.restartDock()
        }
        if old.desktopShortcut {
            _ = try? desktop.remove(name: old.name)
            try desktop.create(target: newURL, name: new.name)
        }
        if new.terminalCommand { try terminal.install(new) }
    }

    func deleteProfile(id: UUID) async throws {
        try await friendly {
            guard let profile = try await store.profile(id: id) else { return }
            try await withQuit([.profile(id)], what: "delete it") { [paths, store, state, journal, dock, desktop, terminal] in
                let entry = try journal.begin(.deleteProfile, payload: ["profileID": id.uuidString])
                if dock.isInDock(bundleID: profile.bundleIdentifier) { try? dock.remove(bundleID: profile.bundleIdentifier) }
                _ = try? desktop.remove(name: profile.name)
                try? terminal.uninstall(profile)
                try await BundleBuilder(paths: paths, agentBinary: URL(filePath: "/dev/null")).remove(profile)
                let fm = FileManager.default
                for dir in [paths.dataDir(for: id), paths.cliConfigDir(for: id)] where fm.fileExists(atPath: dir.path) {
                    try SafePath.require(dir, in: paths)
                    try fm.trashItem(at: dir, resultingItemURL: nil)
                }
                try await store.remove(id: id)
                try? await state.forget(id)
                QuitToken.remove(paths: paths, profileID: id)
                try journal.complete(entry.id)
            }
            HotKeyCenter.shared.unregister(id)
            lastActiveDates[.profile(id)] = nil
            _ = try await loadProfiles()
        }
    }

    func rebuildApp(id: UUID) async throws {
        try await friendly {
            guard let profile = try await store.profile(id: id) else { throw ServiceError("That profile no longer exists.") }
            if isRunningNow(.profile(id)) { throw ServiceError("Quit \(profile.name) first, then rebuild its app.") }
            try await builder().build(profile)
        }
    }

    func appURL(for profile: Profile) -> URL { paths.appURL(forName: profile.name) }

    // MARK: Instances

    func runningInstances() async -> [ClaudeInstance] {
        let scanner = scanner
        let fresh = await Task.detached(priority: .utility) { scanner.claudeInstances() }.value
        instances = fresh
        let now = Date()
        for instance in fresh {
            guard let target = Self.target(of: instance.kind) else { continue }
            // Running targets count as active; persist at most once a minute, immediately when frontmost.
            if instance.isFrontmost || now.timeIntervalSince(lastMarked[target] ?? .distantPast) > 60 {
                markActive(target, at: now)
            }
        }
        return fresh
    }

    func lastActive(_ target: ClaudeTarget) -> Date? { lastActiveDates[target] }

    func open(_ target: ClaudeTarget) async throws {
        try await friendly {
            switch target {
            case .regular:
                if let instance = instance(for: .regular, in: scanner.claudeInstances()) {
                    _ = ClaudeLauncher.activateNow(pid: instance.pid)
                } else {
                    try await launchRegular(urls: [])
                }
            case .profile(let id):
                let url = try await ensureApp(id)
                try await openApp(url, arguments: [])
            }
            markActive(target, at: Date())
        }
    }

    func bringToFront(_ target: ClaudeTarget) async throws {
        try await friendly {
            if let instance = instance(for: target, in: scanner.claudeInstances()) {
                if !ClaudeLauncher.activateNow(pid: instance.pid), case .profile = target {
                    try await open(target)
                }
                markActive(target, at: Date())
            } else {
                try await open(target)
            }
        }
    }

    func quit(_ target: ClaudeTarget) async throws {
        try await friendly {
            guard let instance = instance(for: target, in: scanner.claudeInstances()) else { return }
            if case .profile(let id) = target {
                // Ask the agent first so it doesn't treat the exit as a self-update.
                // Authenticated with the per-profile secret; the agent ignores the request without it.
                if let token = try? QuitToken.load(paths: paths, profileID: id) {
                    DistributedNotificationCenter.default().postNotificationName(
                        IPC.quitProfile, object: id.uuidString, userInfo: [QuitToken.userInfoKey: token], deliverImmediately: true)
                }
                if await waitForExit(instance.pid, timeout: .seconds(6)) { return }
            }
            NSRunningApplication(processIdentifier: instance.pid)?.terminate()
            if await waitForExit(instance.pid, timeout: .seconds(10)) { return }
            throw ServiceError("\(name(of: target)) didn't quit. It may be waiting for you to confirm something.")
        }
    }

    func accountID(for target: ClaudeTarget) -> String? {
        if let cached = accountCache[target], Date().timeIntervalSince(cached.at) < 10 { return cached.value }
        let value = ClaudeDataDir(dataDir(of: target)).accountUUID()
        accountCache[target] = (value, Date())
        return value
    }

    func claudeDesktop() -> ClaudeDesktopInfo? {
        guard let install = claudeInstallation() else { return nil }
        return ClaudeDesktopInfo(appURL: install.url, version: install.displayVersion)
    }

    // MARK: Usage

    func usage(for target: ClaudeTarget) -> PlanUsageInfo {
        let samples = ClaudeDataDir(dataDir(of: target)).planUsageSamples()
        guard let snap = PlanUsage.snapshot(samples) else { return .unknown }
        return PlanUsageInfo(fiveHour: snap.fiveHour, weekly: snap.sevenDay, updatedAt: snap.updatedAt)
    }

    // MARK: Switching

    func isInDock(_ profile: Profile) -> Bool { dock.isInDock(bundleID: profile.bundleIdentifier) }

    func setInDock(_ inDock: Bool, profile: Profile) async throws {
        try await friendly {
            if inDock {
                let url = try await ensureApp(profile.id)
                try dock.add(appURL: url, label: Slug.appName(profile.name), bundleID: profile.bundleIdentifier)
            } else {
                try dock.remove(bundleID: profile.bundleIdentifier)
            }
            try await dock.restartDock()
        }
    }

    func isOnDesktop(_ profile: Profile) -> Bool {
        desktop.exists(name: profile.name) && desktop.isOurs(desktop.shortcutURL(forName: profile.name))
    }

    func setDesktopShortcut(_ enabled: Bool, profile: Profile) async throws {
        try await friendly {
            if enabled {
                let url = try await ensureApp(profile.id)
                try desktop.create(target: url, name: profile.name)
            } else {
                _ = try desktop.remove(name: profile.name)
            }
            try await store.update(id: profile.id) { $0.desktopShortcut = enabled }
            _ = try await loadProfiles()
        }
    }

    func setHotKey(_ spec: HotKeySpec?, profile: Profile) async throws {
        try await friendly {
            if let spec {
                if let other = profiles.first(where: { $0.id != profile.id && $0.hotKey == spec }) {
                    throw ServiceError("\(other.name) already uses this shortcut.")
                }
                try registerHotKey(spec, for: profile.id)
            } else {
                HotKeyCenter.shared.unregister(profile.id)
            }
            try await store.update(id: profile.id) { $0.hotKey = spec }
            _ = try await loadProfiles()
        }
    }

    private func registerHotKey(_ spec: HotKeySpec, for id: UUID) throws {
        try HotKeyCenter.shared.register(spec, for: id) { [weak self] in
            Task { try? await self?.open(.profile(id)) }
        }
    }

    private func registerAllHotKeys() {
        for profile in profiles {
            guard let spec = profile.hotKey else { continue }
            do { try registerHotKey(spec, for: profile.id) } catch {
                log.error("hotkey for \(profile.id.uuidString, privacy: .public) not registered: \(Self.message(error), privacy: .public)")
            }
        }
    }

    // MARK: Terminal command

    func terminalCommandName(for profile: Profile) -> String { Slug.terminalCommand(for: profile.name) }

    func setTerminalCommand(_ enabled: Bool, profile: Profile) async throws {
        try await friendly {
            guard let current = try await store.profile(id: profile.id) else { throw ServiceError("That profile no longer exists.") }
            if enabled { try terminal.install(current) } else { try terminal.uninstall(current) }
            try await store.update(id: profile.id) { $0.terminalCommand = enabled }
            _ = try await loadProfiles()
        }
    }

    // MARK: Bring over from regular Claude

    func importPreview(profile: Profile) async throws -> ImportPreview {
        try await friendly {
            try requireQuit(.profile(profile.id), "import settings into it")
            let source = ClaudeDataDir(paths.regularClaudeDir), dest = ClaudeDataDir(paths.dataDir(for: profile.id))
            let plan = try await offMain { try SettingsImportPlanner.plan(from: source, to: dest) }
            importPlans[profile.id] = plan
            var items: [ImportItem] = []
            items += plan.addedMCPServers.map { ImportItem(kind: .mcpServer, name: $0) }
            items += plan.addedPreferences.map { ImportItem(kind: .preference, name: $0) }
            items += plan.addedTopLevelKeys.map { ImportItem(kind: .setting, name: $0) }
            items += plan.addedExtensions.map { ImportItem(kind: .extensionItem, name: $0) }
            if plan.copiesDeveloperSettings { items.append(ImportItem(kind: .developerSettings, name: "developer_settings.json")) }
            let sourceServers = ((try? AtomicFile.readJSONObject(at: source.desktopConfigJSON))?["mcpServers"] as? [String: Any])?.count ?? 0
            return ImportPreview(items: items, alreadyPresent: max(0, sourceServers - plan.addedMCPServers.count))
        }
    }

    func executeImport(_ preview: ImportPreview, profile: Profile) async throws -> Int {
        try await friendly {
            guard importPlans[profile.id] != nil else { throw ServiceError("The preview expired. Open Import again.") }
            importPlans[profile.id] = nil
            let paths = paths
            let source = ClaudeDataDir(paths.regularClaudeDir), dest = ClaudeDataDir(paths.dataDir(for: profile.id))
            return try await withQuit([.profile(profile.id)], what: "import settings into it") {
                // Re-plan under the lock so nothing changed since the preview is overwritten.
                let plan = try SettingsImportPlanner.plan(from: source, to: dest)
                _ = try SettingsImportExecutor(paths: paths).execute(plan, into: dest)
                return plan.addedMCPServers.count + plan.addedPreferences.count + plan.addedTopLevelKeys.count
                    + plan.addedExtensions.count + (plan.copiesDeveloperSettings ? 1 : 0)
            }
        }
    }

    func syncPreview(profile: Profile, direction: SyncDirection) async throws -> SyncPreview {
        try await friendly {
            try requireQuit(.profile(profile.id), "sync sessions")
            try requireQuit(.regular, "sync sessions")
            let regular = ClaudeDataDir(paths.regularClaudeDir), prof = ClaudeDataDir(paths.dataDir(for: profile.id))
            let regularAccount = regular.accountUUID(), profileAccount = prof.accountUUID()
            guard regularAccount != nil else { throw ServiceError("Regular Claude isn't signed in, so there are no sessions to sync.") }
            guard profileAccount != nil else { throw ServiceError("Sign in to \(profile.name) once before syncing sessions.") }
            let same = SessionSyncPlanner.sameAccount(regularAccount, profileAccount)
            let effective: SyncDirection = same ? direction : (direction == .both ? .regularToProfile : direction)
            let oneWay: SyncSide? = switch effective {
            case .both: nil
            case .regularToProfile: .a
            case .profileToRegular: .b
            }
            let backupRoot = SessionSyncPlanner.backupRoot(paths: paths)
            let plan = try await offMain {
                try SessionSyncPlanner.plan(a: SessionInventory.scan(regular.sessionsDir), aAccount: regularAccount,
                                            b: SessionInventory.scan(prof.sessionsDir), bAccount: profileAccount,
                                            oneWayFrom: oneWay, backupRoot: backupRoot)
            }
            let items = plan.copies.map { copy -> SyncItem in
                let info = Self.sessionSummary(copy.source)
                let action: SyncAction = switch (copy.from, copy.replaces) {
                case (.a, false): .copyToProfile
                case (.a, true): .updateProfile
                case (.b, false): .copyToRegular
                case (.b, true): .updateRegular
                }
                return SyncItem(id: "\(copy.from == .a ? "r" : "p")/\(copy.sessionId)", title: info.title ?? copy.sessionId,
                                cwd: info.cwd.map(abbreviate), action: action, lastActivity: info.lastActivity)
            }
            let unchanged = plan.skippedIdentical.count + plan.skippedTombstoned.count + plan.skippedNotNewer.count
            let preview = SyncPreview(sameAccount: same, direction: effective, items: items, unchanged: unchanged)
            syncPlans[profile.id] = (preview, plan)
            return preview
        }
    }

    func executeSync(_ preview: SyncPreview, profile: Profile) async throws -> Int {
        try await friendly {
            guard let cached = syncPlans[profile.id], cached.preview == preview else {
                throw ServiceError("The preview is out of date. Review the sync again.")
            }
            syncPlans[profile.id] = nil
            let plan = cached.plan, paths = paths, journal = journal
            return try await withQuit([.profile(profile.id), .regular], what: "sync sessions") {
                let entry = try journal.begin(.sessionSync, payload: ["profileID": profile.id.uuidString])
                let result = try SessionSyncExecutor(paths: paths).execute(plan)
                try journal.complete(entry.id)
                return result.copied.count
            }
        }
    }

    /// Title, cwd and last activity from a session record, for the preview list only.
    nonisolated private static func sessionSummary(_ url: URL) -> (title: String?, cwd: String?, lastActivity: Date?) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil, nil) }
        let cwd = obj["cwd"] as? String
        let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? cwd.map { ($0 as NSString).lastPathComponent }
        let ms = (obj["lastActivityAt"] as? NSNumber)?.doubleValue
        return (title, cwd, ms.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    // MARK: Backup & storage

    func storage(for target: ClaudeTarget) async -> StorageInfo {
        let dir = dataDir(of: target)
        return await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: dir.path) else { return StorageInfo(dataBytes: 0, cacheBytes: 0) }
            return StorageInfo(dataBytes: CacheInventory.size(of: dir), cacheBytes: CacheInventory.cacheSize(in: dir))
        }.value
    }

    func clearCache(_ target: ClaudeTarget) async throws {
        try await friendly {
            guard case .profile(let id) = target else {
                throw ServiceError("Regular Claude's folder is never modified by this app.")
            }
            let paths = paths, dir = paths.dataDir(for: id)
            try await withQuit([target], what: "clear its cache") {
                for cache in CacheInventory.cacheDirs(in: dir) {
                    try SafePath.require(cache, within: [paths.profilesDir])
                    try FileManager.default.removeItem(at: cache)
                }
            }
        }
    }

    func exportBackup(profile: Profile, to destination: URL) async throws {
        try await friendly {
            let archiver = BackupArchiver(paths: paths, appVersion: appVersion)
            try await withQuit([.profile(profile.id)], what: "export a backup") {
                _ = try await archiver.export(profile, to: destination)
            }
        }
    }

    func regularClaudeHasData() -> Bool { ClaudeDataDir(paths.regularClaudeDir).exists }

    // MARK: Memory

    func memoryOverview() async throws -> MemoryOverview {
        let memory = MemoryStore(paths: paths)
        let (projects, lines) = await Task.detached(priority: .userInitiated) {
            (memory.projects(), memory.generalRulesLineCount())
        }.value
        let exists = FileManager.default.fileExists(atPath: memory.generalRulesURL.path)
        return MemoryOverview(
            generalRulesURL: memory.generalRulesURL,
            generalRulesLineCount: exists ? lines : nil,
            projects: projects.map { project in
                MemoryProjectInfo(
                    id: project.dirName,
                    name: (project.displayPath as NSString).lastPathComponent,
                    displayPath: abbreviate(project.displayPath),
                    notes: project.notes.map {
                        MemoryNoteInfo(projectID: project.dirName, fileName: $0.fileName, title: $0.title,
                                       type: $0.type, summary: $0.description.isEmpty ? nil : $0.description, url: $0.url)
                    })
            })
    }

    func memoryConflicts(notes: [MemoryNoteInfo], project: MemoryProjectInfo) -> [String] {
        guard let dir = memoryDir(project.id) else { return [] }
        return notes.filter { $0.projectID != project.id && FileManager.default.fileExists(atPath: dir.appending(path: $0.fileName).path) }
            .map(\.fileName)
    }

    func copyNotes(_ notes: [MemoryNoteInfo], to project: MemoryProjectInfo, policy: MemoryConflictPolicy) async throws -> MemoryOpResult {
        try await friendly {
            guard let dir = memoryDir(project.id) else { throw ServiceError("That project folder name isn't valid.") }
            let candidates = notes.filter { $0.projectID != project.id }
            let loaded = candidates.compactMap { MemoryStore.loadNote($0.url, project: $0.projectID) }
            let conflicts = Set(memoryConflicts(notes: candidates, project: project))
            let resolution: ConflictResolution = switch policy {
            case .replace: .replace
            case .keepBoth: .keepBoth
            case .skip: .skip
            }
            let backup = MemoryOps.backupDir(paths: paths)
            try SafePath.require(dir, in: paths)
            let result = try await offMain {
                try MemoryOps.copy(loaded, toMemoryDir: dir, backupDir: backup) { _ in resolution }
            }
            let replaced = policy == .replace ? loaded.filter { conflicts.contains($0.fileName) }.count : 0
            return MemoryOpResult(written: result.written.count - replaced, replaced: replaced,
                                  skipped: result.skipped.count + (notes.count - loaded.count))
        }
    }

    func makeGeneralRules(_ notes: [MemoryNoteInfo]) async throws -> MemoryOpResult {
        try await friendly {
            let loaded = notes.compactMap { MemoryStore.loadNote($0.url, project: $0.projectID) }
            let claudeMD = MemoryStore(paths: paths).generalRulesURL
            let backup = MemoryOps.backupDir(paths: paths)
            let added = try await offMain { try MemoryOps.makeGeneralRules(loaded, claudeMD: claudeMD, backupDir: backup) }
            return MemoryOpResult(written: added, replaced: 0, skipped: notes.count - added)
        }
    }

    private func memoryDir(_ projectID: String) -> URL? {
        guard SafePath.isSafeComponent(projectID) else { return nil }
        return MemoryStore(paths: paths).projectsDir.appending(path: projectID, directoryHint: .isDirectory)
            .appending(path: "memory", directoryHint: .isDirectory)
    }

    // MARK: Finder

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openFolder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) } else { revealInFinder(url.deletingLastPathComponent()) }
    }

    func openInEditor(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path), url.lastPathComponent == "CLAUDE.md" {
            try? AtomicFile.write("", to: url)
        }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Settings

    func loadSettings() -> AppSettings { settings }

    func saveSettings(_ new: AppSettings) async throws {
        try await friendly {
            let previous = settings
            if new.routeLinks && !previous.routeLinks && Bundle.main.bundleURL.pathExtension != "app" {
                throw ServiceError("Link routing needs the installed app (build it with scripts/build-app.sh).")
            }
            if new.launchAtLogin != previous.launchAtLogin { try LoginItem.setEnabled(new.launchAtLogin) }
            let core = Self.coreSettings(new)
            try await state.updateSettings { $0 = core }
            settings = new
            await applyRuntimeSettings(previous: previous)
        }
    }

    /// Starts/stops link routing and music pause to match `settings`.
    private func applyRuntimeSettings(previous: AppSettings?) async {
        if settings.routeLinks != previous?.routeLinks {
            if settings.routeLinks {
                if Bundle.main.bundleURL.pathExtension == "app" {
                    let registration = linkRegistration ?? LinkHandlerRegistration(
                        ourAppURL: Bundle.main.bundleURL, claudeAppURL: { [weak self] in self?.claudeInstallation()?.url })
                    linkRegistration = registration
                    do { try await registration.enable() } catch {
                        log.error("claiming claude:// failed: \(Self.message(error), privacy: .public)")
                    }
                }
            } else if previous != nil, let registration = linkRegistration {
                try? await registration.disable()
            }
        }
        if settings.pauseMusicWhileDictating != previous?.pauseMusicWhileDictating {
            if settings.pauseMusicWhileDictating {
                if musicPause == nil { musicPause = MusicPauseCoordinator() }
                musicPause?.start()
            } else {
                musicPause?.stop()
            }
        }
    }

    private static func uiSettings(_ core: CMACore.AppSettings) -> AppSettings {
        AppSettings(launchAtLogin: core.launchAtLogin, showLetterInMenuBar: core.menuBarLetter, routeLinks: core.linkRoutingEnabled,
                    pauseMusicWhileDictating: core.musicPauseEnabled, onboardingCompleted: core.onboardingCompleted)
    }

    private static func coreSettings(_ ui: AppSettings) -> CMACore.AppSettings {
        CMACore.AppSettings(onboardingCompleted: ui.onboardingCompleted, linkRoutingEnabled: ui.routeLinks,
                            musicPauseEnabled: ui.pauseMusicWhileDictating, menuBarLetter: ui.showLetterInMenuBar,
                            launchAtLogin: ui.launchAtLogin)
    }

    // MARK: Links

    /// A claude:// link arrived at the manager (kAEGetURL). 0 running → regular Claude, 1 → it, more → picker.
    private func handleIncomingLink(_ url: URL) {
        Task {
            let running = await runningInstances()
            var activity: [UUID: Date] = [:]
            for case let (.profile(id), date) in lastActiveDates.map({ ($0.key, $0.value) }) { activity[id] = date }
            switch LinkRouting.decide(url: url, instances: running, lastActiveAt: activity) {
            case .reject:
                log.notice("ignored an invalid claude:// link")
            case .openRegular:
                do { try await launchRegular(urls: [url]) } catch { log.error("opening link failed: \(Self.message(error), privacy: .public)") }
            case .forward(let pid):
                do {
                    try URLForwarder.forward(url, toPID: pid)
                    _ = ClaudeLauncher.activateNow(pid: pid)
                } catch {
                    log.error("forwarding link failed: \(Self.message(error), privacy: .public)")
                }
            case .pick(let candidates, let preselected):
                let targets = candidates.compactMap { Self.target(of: $0.kind) }
                let pre = candidates.first { $0.pid == preselected }.flatMap { Self.target(of: $0.kind) }
                linkContinuation?.yield(LinkRequest(url: url, candidates: targets, preselected: pre))
            }
        }
    }

    func route(_ url: URL, to target: ClaudeTarget) async throws {
        try await friendly {
            guard LinkRouting.isValid(url) else { throw ServiceError("That link isn't a valid claude:// link.") }
            if let instance = instance(for: target, in: scanner.claudeInstances()) {
                try URLForwarder.forward(url, toPID: instance.pid)
                _ = ClaudeLauncher.activateNow(pid: instance.pid)
            } else {
                switch target {
                case .regular: try await launchRegular(urls: [url])
                case .profile(let id):
                    let app = try await ensureApp(id)
                    try await openApp(app, arguments: [IPC.openURLArgument, url.absoluteString])
                }
            }
            markActive(target, at: Date())
        }
    }

    // MARK: Helpers

    private func builder() throws -> BundleBuilder {
        guard let agent = Self.agentBinary() else {
            throw ServiceError("The profile launcher (ProfileAgent) is missing from this app. Reinstall Claude Multi Account.")
        }
        return BundleBuilder(paths: paths, agentBinary: agent, appVersion: appVersion)
    }

    /// `Contents/Resources/ProfileAgent` in the app bundle; next to the executable for `swift run` builds.
    static func agentBinary() -> URL? {
        if let bundled = BundleBuilder.bundledAgent(in: .main) { return bundled }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: ProfileInfoPlist.executableName)
        if let sibling, FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        return nil
    }

    /// Returns the profile app, building it when missing (or stale and not running).
    private func ensureApp(_ id: UUID) async throws -> URL {
        guard let profile = try await store.profile(id: id) else { throw ServiceError("That profile no longer exists.") }
        let builder = try builder()
        let url = builder.appURL(for: profile)
        let missing = !FileManager.default.fileExists(atPath: url.path)
        if missing || (!isRunningNow(.profile(id)) && (try? builder.needsRebuild(profile)) == true) {
            try await builder.build(profile)
        }
        return url
    }

    private func openApp(_ url: URL, arguments: [String]) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        config.arguments = arguments
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// A new regular (flagless) Claude instance, optionally opening links in it.
    private func launchRegular(urls: [URL]) async throws {
        guard let claude = claudeInstallation()?.url else {
            throw ServiceError("Claude Desktop isn't installed. Download it from claude.ai/download.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = true
        if urls.isEmpty {
            _ = try await NSWorkspace.shared.openApplication(at: claude, configuration: config)
        } else {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: claude, configuration: config)
        }
    }

    private func claudeInstallation() -> ClaudeInstallation? {
        if let cached = claudeInfo, Date().timeIntervalSince(cached.at) < 30 { return cached.value }
        let value = ClaudeLocator(paths: paths).locate()
        claudeInfo = (value, Date())
        return value
    }

    private func makeMover() -> RegularClaudeMover {
        let scanner = scanner
        return RegularClaudeMover(paths: paths, isRegularClaudeRunning: {
            scanner.claudeInstances().mayBeRunning(.regular)
        })
    }

    private func dataDir(of target: ClaudeTarget) -> URL {
        switch target {
        case .regular: paths.regularClaudeDir
        case .profile(let id): paths.dataDir(for: id)
        }
    }

    private func name(of target: ClaudeTarget) -> String {
        switch target {
        case .regular: "Regular Claude"
        case .profile(let id): profiles.first { $0.id == id }?.name ?? "The profile"
        }
    }

    private static func target(of kind: InstanceKind) -> ClaudeTarget? {
        switch kind {
        case .regular: .regular
        case .profile(let id): .profile(id)
        case .foreign: nil
        }
    }

    private func instance(for target: ClaudeTarget, in list: [ClaudeInstance]) -> ClaudeInstance? {
        list.first { Self.target(of: $0.kind) == target }
    }

    /// Quit gate. A Claude process whose arguments can't be read counts as possibly `target`.
    private func isRunningNow(_ target: ClaudeTarget) -> Bool {
        let list = scanner.claudeInstances()
        return instance(for: target, in: list) != nil || list.contains { $0.kind.isUnidentified }
    }

    private func requireQuit(_ target: ClaudeTarget, _ what: String) throws {
        if isRunningNow(target) { throw ServiceError("Quit \(name(of: target)) first, then \(what).") }
    }

    /// Every data-dir mutation runs here: take each dir's lock, assert nothing runs on it, then run `body`.
    private func withQuit<T: Sendable>(_ targets: [ClaudeTarget], what: String,
                                       _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        var locks: [DataDirLock] = []
        defer { locks.forEach { $0.unlock() } }
        for target in targets {
            try requireQuit(target, what)
            let lock = DataDirLock(paths: paths, dataDir: dataDir(of: target))
            guard try lock.tryLock() else {
                throw ServiceError("\(name(of: target)) is in use right now. Quit it first, then \(what).")
            }
            locks.append(lock)
        }
        // Re-check after locking: something may have launched in between.
        for target in targets { try requireQuit(target, what) }
        return try await body()
    }

    private func waitForExit(_ pid: Int32, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return kill(pid, 0) != 0
    }

    private func markActive(_ target: ClaudeTarget, at date: Date) {
        lastActiveDates[target] = date
        lastMarked[target] = date
        let key: UUID = switch target {
        case .regular: Self.regularKey
        case .profile(let id): id
        }
        let state = state
        Task { try? await state.markActive(key, at: date) }
    }

    private func abbreviate(_ path: String) -> String {
        var home = paths.home.path(percentEncoded: false)
        if home.hasSuffix("/") { home.removeLast() }
        return path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// Runs `body`, turning module errors into messages people can act on.
    private func friendly<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let error as ServiceError { throw error } catch {
            throw ServiceError(Self.message(error))
        }
    }

    nonisolated static func message(_ error: Error) -> String {
        switch error {
        case let e as ServiceError: return e.message
        case let e as NameValidationError: return e.message
        case let e as RegularClaudeMoveError:
            switch e {
            case .sourceMissing: return "Regular Claude has no data to move."
            case .destinationExists: return "A folder for this profile already exists."
            case .claudeRunning: return "Quit regular Claude first, then move it."
            case .renameFailed(let code): return "Moving the folder failed (\(String(cString: strerror(code))))."
            case .verificationFailed(let path): return "The copy didn't match the original (\(path)). Nothing was removed."
            }
        case let e as BackupError:
            switch e {
            case .dataDirMissing: return "This profile has no data to back up yet."
            case .invalidArchive(let why): return "That file isn't a valid backup (\(why))."
            case .unsupportedVersion(let v): return "This backup was made by a newer version (format \(v))."
            case .unsafeEntry: return "That backup contains unsafe paths and was not restored."
            case .toolFailed(let why): return "Archiving failed: \(why)"
            }
        case let e as TerminalCommandError:
            switch e {
            case .foreignFileExists(let p): return "\(p) already exists and isn't ours, so it was left alone."
            case .ownedByOtherProfile(let p): return "\(p) belongs to another profile."
            case .noWritableBinDir: return "Neither ~/.local/bin nor /usr/local/bin is writable."
            }
        case let e as DesktopShortcutError:
            switch e {
            case .foreignFileExists(let p): return "\(p) already exists on the Desktop and isn't ours."
            case .targetMissing: return "The profile app is missing. Use Rebuild App first."
            }
        case let e as HotKeyError:
            switch e {
            case .noModifier: return "Use at least one of ⌘, ⌥, ⌃ or ⇧."
            case .alreadyInUse: return "Another app already uses this shortcut."
            case .registrationFailed(let s): return "The shortcut couldn't be registered (\(s))."
            }
        case let e as SessionSyncError:
            switch e {
            case .unknownAccount: return "Both sides need to be signed in before syncing."
            case .directionRequired: return "Choose which way to copy, because the accounts differ."
            case .noDestinationOrg: return "Use Claude Code once on the receiving side so it has a place for sessions."
            case .ambiguousDestinationOrg: return "The receiving account belongs to several organizations, so the destination is unclear."
            }
        case let e as SessionSyncExecutionError:
            return "Sync stopped safely: \(e). Anything replaced so far was backed up."
        case let e as BundleBuilderError:
            switch e {
            case .agentMissing: return "The profile launcher is missing from this app. Reinstall Claude Multi Account."
            case .signFailed(let why), .verifyFailed(let why): return "Signing the profile app failed: \(why)"
            }
        case let e as ClaudeLaunchError:
            switch e {
            case .claudeNotFound: return "Claude Desktop isn't installed."
            case .launchFailed(let why), .urlForwardFailed(let why): return why
            case .invalidURL: return "That link isn't a valid claude:// link."
            }
        case let e as URLForwarderError:
            switch e {
            case .invalidURL: return "That link isn't a valid claude:// link."
            case .sendFailed(let why): return "Couldn't hand the link to Claude: \(why)"
            }
        case let e as DockEditorError:
            switch e {
            case .readFailed: return "Couldn't read the current Dock, so it was left unchanged. Try again in a moment."
            case .syncFailed: return "Couldn't save the Dock change."
            }
        case let e as SafePathError: return "Refused to touch a path outside the app's folders (\(e))."
        case is DataDirLockError: return "Couldn't lock the profile's data folder."
        case let e as ProfileStoreError:
            switch e {
            case .duplicateID: return "A profile with this ID already exists."
            case .notFound: return "That profile no longer exists."
            }
        default: return error.localizedDescription
        }
    }
}

/// Receives claude:// links from the GURL Apple Event handler (installed before launch finishes)
/// and holds them until the services attach.
@MainActor
final class LinkInbox {
    static let shared = LinkInbox()
    private var handler: ((URL) -> Void)?
    private var buffered: [URL] = []

    func attach(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        let pending = buffered
        buffered = []
        pending.forEach(handler)
    }

    func receive(_ url: URL) {
        guard LinkRouting.isValid(url) else { return }
        if let handler { handler(url) } else { buffered.append(url) }
    }
}
