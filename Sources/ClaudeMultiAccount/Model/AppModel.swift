import AppKit
import Observation
import CMACore

enum ActiveSheet: Identifiable, Equatable {
    case newProfile(NewProfileSource?)
    case edit(UUID)
    case sync(UUID)
    case importSettings(UUID)
    case onboarding

    var id: String {
        switch self {
        case .newProfile: "new"
        case .edit(let id): "edit-\(id)"
        case .sync(let id): "sync-\(id)"
        case .importSettings(let id): "import-\(id)"
        case .onboarding: "onboarding"
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@Observable
@MainActor
final class AppModel {
    let services: any ProfileServices

    private(set) var profiles: [Profile] = []
    private(set) var instances: [ClaudeInstance] = []
    private(set) var usage: [ClaudeTarget: PlanUsageInfo] = [:]
    private(set) var storage: [ClaudeTarget: StorageInfo] = [:]
    private(set) var settings = AppSettings()
    private(set) var memory: MemoryOverview?
    private(set) var busy: Set<String> = []

    var selection: SidebarItem? = .regular
    var searchText = ""
    var activeSheet: ActiveSheet?
    var alert: AppAlert?
    /// Link waiting for the user to pick a target; the link picker window shows the first one.
    private(set) var pendingLinks: [LinkRequest] = []

    private var started = false
    private var tick = 0
    private var visibleWindows = 0
    private var observers: [NSObjectProtocol] = []

    init(services: any ProfileServices) {
        self.services = services
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        services.start()
        settings = services.loadSettings()
        Task {
            await reloadProfiles()
            await refreshInstances()
            refreshUsage()
            if !settings.onboardingCompleted { activeSheet = .onboarding }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                await self.refreshInstances()
                self.tick += 1
                if self.tick % 15 == 0 { self.refreshUsage() }
            }
        }
        Task { [weak self, stream = services.linkRequests] in
            for await request in stream {
                self?.pendingLinks.append(request)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refreshInstances() }
                }
            })
        }
    }

    func reloadProfiles() async {
        do { profiles = try await services.loadProfiles() } catch { show(error, title: "Couldn't load profiles") }
    }

    func refreshInstances() async {
        let fresh = await services.runningInstances()
        if fresh != instances { instances = fresh }
    }

    func refreshUsage() {
        var next: [ClaudeTarget: PlanUsageInfo] = [.regular: services.usage(for: .regular)]
        for profile in profiles { next[.profile(profile.id)] = services.usage(for: .profile(profile.id)) }
        usage = next
    }

    func refreshStorage(_ target: ClaudeTarget) async {
        storage[target] = await services.storage(for: target)
    }

    func loadMemory() async {
        do { memory = try await services.memoryOverview() } catch { show(error, title: "Couldn't read memory") }
    }

    // MARK: Activation policy

    func windowAppeared() {
        visibleWindows += 1
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    func windowDisappeared() {
        visibleWindows = max(0, visibleWindows - 1)
        if visibleWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: Derived state

    var filteredProfiles: [Profile] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return profiles }
        return profiles.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }

    func instance(for target: ClaudeTarget) -> ClaudeInstance? {
        instances.first { instance in
            switch (instance.kind, target) {
            case (.regular, .regular): true
            case (.profile(let a), .profile(let b)): a == b
            default: false
            }
        }
    }

    func runState(_ target: ClaudeTarget) -> RunState {
        guard let instance = instance(for: target) else { return .notRunning }
        return instance.isFrontmost ? .runningInFront : .running
    }

    func isRunning(_ target: ClaudeTarget) -> Bool { instance(for: target) != nil }

    /// Open profiles first (front one first), then the rest in saved order.
    var menuOrderedProfiles: [Profile] {
        let open = profiles.filter { isRunning(.profile($0.id)) }
            .sorted { runState(.profile($0.id)) == .runningInFront && runState(.profile($1.id)) != .runningInFront }
        return open + profiles.filter { !isRunning(.profile($0.id)) }
    }

    var frontProfile: Profile? {
        profiles.first { runState(.profile($0.id)) == .runningInFront }
    }

    /// Names of other profiles (or regular Claude) signed in to the same account.
    func sharedAccountNames(for profile: Profile) -> [String] {
        guard let account = services.accountID(for: .profile(profile.id)) else { return [] }
        var names = profiles.filter { $0.id != profile.id && services.accountID(for: .profile($0.id)) == account }.map(\.name)
        if services.accountID(for: .regular) == account { names.append("Regular Claude") }
        return names
    }

    func statusLine(_ target: ClaudeTarget) -> String {
        let state = runState(target)
        if state.isRunning { return state.label }
        if let date = services.lastActive(target) {
            return "Last active \(date.formatted(.relative(presentation: .named)))"
        }
        if case .regular = target { return "Not running" }
        return "Never opened"
    }

    // MARK: Actions

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    /// Runs a side effect, tracks a busy key, surfaces errors as an alert, then refreshes state.
    func perform(_ key: String, failure: String, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do {
                try await operation()
            } catch {
                show(error, title: failure)
            }
            await refreshInstances()
        }
    }

    func open(_ target: ClaudeTarget) {
        perform("open-\(target)", failure: "Couldn't open") { try await self.services.open(target) }
    }

    func bringToFront(_ target: ClaudeTarget) {
        perform("front-\(target)", failure: "Couldn't bring it to the front") { try await self.services.bringToFront(target) }
    }

    func quit(_ target: ClaudeTarget) {
        perform("quit-\(target)", failure: "Couldn't quit") { try await self.services.quit(target) }
    }

    /// Opens when not running, otherwise brings to front.
    func openOrFront(_ target: ClaudeTarget) {
        isRunning(target) ? bringToFront(target) : open(target)
    }

    func update(_ profile: Profile) {
        perform("update-\(profile.id)", failure: "Couldn't save changes") {
            try await self.services.updateProfile(profile)
            await self.reloadProfiles()
            DistributedNotificationCenter.default().postNotificationName(
                IPC.profileChanged, object: profile.id.uuidString, userInfo: nil, deliverImmediately: true)
        }
    }

    func createProfile(name: String, color: ProfileColor, source: NewProfileSource, completion: @escaping @MainActor (Bool) -> Void) {
        perform("create", failure: "Couldn't create the profile") {
            do {
                if source == .moveRegular, self.isRunning(.regular) {
                    try await self.services.quit(.regular)
                }
                let profile = try await self.services.createProfile(name: name, color: color, source: source)
                await self.reloadProfiles()
                self.refreshUsage()
                self.selection = .profile(profile.id)
                completion(true)
            } catch {
                completion(false)
                throw error
            }
        }
    }

    func delete(_ profile: Profile) {
        perform("delete-\(profile.id)", failure: "Couldn't delete \(profile.name)") {
            try await self.services.deleteProfile(id: profile.id)
            if self.selection == .profile(profile.id) { self.selection = .regular }
            await self.reloadProfiles()
        }
    }

    func rebuild(_ profile: Profile) {
        perform("rebuild-\(profile.id)", failure: "Couldn't rebuild the app") {
            try await self.services.rebuildApp(id: profile.id)
            self.alert = AppAlert(title: "App rebuilt", message: "\(self.appName(profile)) is up to date.")
        }
    }

    func setHotKey(_ spec: HotKeySpec?, for profile: Profile) {
        perform("hotkey-\(profile.id)", failure: "Couldn't set the shortcut") {
            try await self.services.setHotKey(spec, profile: profile)
            await self.reloadProfiles()
        }
    }

    func setInDock(_ value: Bool, _ profile: Profile) {
        perform("dock-\(profile.id)", failure: "Couldn't change the Dock") {
            try await self.services.setInDock(value, profile: profile)
            await self.reloadProfiles()
        }
    }

    func setDesktop(_ value: Bool, _ profile: Profile) {
        perform("desktop-\(profile.id)", failure: "Couldn't change the desktop shortcut") {
            try await self.services.setDesktopShortcut(value, profile: profile)
            await self.reloadProfiles()
        }
    }

    func setTerminal(_ value: Bool, _ profile: Profile) {
        perform("terminal-\(profile.id)", failure: "Couldn't change the terminal command") {
            try await self.services.setTerminalCommand(value, profile: profile)
            await self.reloadProfiles()
        }
    }

    func clearCache(_ target: ClaudeTarget) {
        perform("cache-\(target)", failure: "Couldn't clear the cache") {
            try await self.services.clearCache(target)
            await self.refreshStorage(target)
        }
    }

    func exportBackup(_ profile: Profile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(profile.name) Backup.zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("backup-\(profile.id)", failure: "Couldn't export the backup") {
            try await self.services.exportBackup(profile: profile, to: url)
            self.alert = AppAlert(title: "Backup saved",
                                  message: "Restoring on another Mac needs a fresh sign-in, because Claude encrypts sign-ins with this Mac's keychain.")
        }
    }

    func saveSettings(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        let previous = settings
        settings = next
        Task {
            do { try await services.saveSettings(next) } catch {
                if settings == next { settings = previous }
                show(error, title: "Couldn't save settings")
            }
        }
    }

    func completeOnboarding() {
        saveSettings { $0.onboardingCompleted = true }
    }

    func routePendingLink(to target: ClaudeTarget?) {
        guard !pendingLinks.isEmpty else { return }
        let request = pendingLinks.removeFirst()
        guard let target else { return }
        perform("route", failure: "Couldn't open the link") { try await self.services.route(request.url, to: target) }
    }

    // MARK: Helpers

    func appName(_ profile: Profile) -> String { services.appURL(for: profile).lastPathComponent }

    func displayName(_ target: ClaudeTarget) -> String {
        switch target {
        case .regular: "Regular Claude"
        case .profile(let id): profile(id)?.name ?? "Unknown profile"
        }
    }

    func show(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }

    func abbreviated(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let home = services.paths.home.path(percentEncoded: false)
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        return path.hasPrefix(trimmedHome) ? "~" + path.dropFirst(trimmedHome.count) : path
    }
}
