import Foundation
import CMACore

/// In-memory sample implementation so the UI runs standalone. Touches no files and no processes.
@MainActor
final class MockProfileServices: ProfileServices {
    let paths: AppPaths
    private var profiles: [Profile]
    private var running: [ClaudeTarget: Int32] = [:]
    private var front: ClaudeTarget?
    private var lastActiveDates: [ClaudeTarget: Date] = [:]
    private var dock: Set<UUID> = []
    private var settings = AppSettings()
    private var nextPid: Int32 = 4100
    private var memory: MemoryOverview
    private var linkContinuation: AsyncStream<LinkRequest>.Continuation?
    let linkRequests: AsyncStream<LinkRequest>

    init(emitDemoLink: Bool = false) {
        paths = AppPaths(home: FileManager.default.temporaryDirectory.appending(path: "cma-mock-home"))
        let work = Profile(name: "Work", color: .blue, createdAt: .now.addingTimeInterval(-86_400 * 20),
                           showBorder: true, borderWidth: .medium, terminalCommand: true,
                           hotKey: HotKeySpec(keyCode: 13, modifiers: 0x100 | 0x800))
        let personal = Profile(name: "Personal", color: .green, createdAt: .now.addingTimeInterval(-86_400 * 9))
        let client = Profile(name: "Client Projects", color: .orange, createdAt: .now.addingTimeInterval(-3_600),
                             showBorder: false)
        profiles = [work, personal, client]
        running = [.profile(work.id): 4001, .profile(personal.id): 4002, .regular: 4003]
        front = .profile(work.id)
        lastActiveDates = [.profile(work.id): .now, .profile(personal.id): .now.addingTimeInterval(-600),
                           .regular: .now.addingTimeInterval(-7_200)]
        dock = [work.id]

        let home = paths.home
        func note(_ project: String, _ file: String, _ type: String, _ summary: String) -> MemoryNoteInfo {
            MemoryNoteInfo(projectID: project, fileName: "\(file).md", title: file, type: type, summary: summary,
                           url: home.appending(path: ".claude/projects/\(project)/memory/\(file).md"))
        }
        let p1 = "-Users-demo-Code-Inventory"
        let p2 = "-Users-demo-Code-Website"
        let p3 = "-Users-demo-Code-Firmware"
        memory = MemoryOverview(
            generalRulesURL: home.appending(path: ".claude/CLAUDE.md"),
            generalRulesLineCount: 24,
            projects: [
                MemoryProjectInfo(id: p1, name: "Inventory", displayPath: "~/Code/Inventory", notes: [
                    note(p1, "build-steps", "project", "How to build and run the importer"),
                    note(p1, "db-conventions", "project", "Table naming and migration rules"),
                    note(p1, "api-reference", "reference", "Endpoints used by the sync job"),
                ]),
                MemoryProjectInfo(id: p2, name: "Website", displayPath: "~/Code/Website", notes: [
                    note(p2, "deploy", "project", "Preview and production deploy flow"),
                    note(p2, "style-guide", "feedback", "Copy tone and component rules"),
                ]),
                MemoryProjectInfo(id: p3, name: "Firmware", displayPath: "~/Code/Firmware", notes: [
                    note(p3, "flashing", "project", "Flashing over USB and OTA"),
                ]),
            ])

        var continuation: AsyncStream<LinkRequest>.Continuation?
        linkRequests = AsyncStream { continuation = $0 }
        linkContinuation = continuation

        if emitDemoLink {
            let request = LinkRequest(url: URL(string: "claude://claude.ai/new?q=hello")!,
                                      candidates: [.profile(work.id), .profile(personal.id), .regular],
                                      preselected: .profile(work.id))
            Task { [continuation] in
                try? await Task.sleep(for: .seconds(1.5))
                continuation?.yield(request)
            }
        }
    }

    private func pretend() async { try? await Task.sleep(for: .milliseconds(350)) }

    private func requireQuit(_ target: ClaudeTarget, _ what: String) throws {
        if running[target] != nil { throw ServiceError("Quit it first, then \(what).") }
    }

    // MARK: Profiles
    func loadProfiles() async throws -> [Profile] { profiles }

    func validateName(_ name: String, excluding id: UUID?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Enter a name." }
        if trimmed.count > 40 { return "Use 40 characters or fewer." }
        if trimmed.contains("/") || trimmed.contains(":") { return "Names can't contain / or :." }
        if trimmed.hasPrefix(".") { return "Names can't start with a dot." }
        if profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "Another profile already uses this name."
        }
        return nil
    }

    func createProfile(name: String, color: ProfileColor, source: NewProfileSource) async throws -> Profile {
        await pretend()
        if let error = validateName(name, excluding: nil) { throw ServiceError(error) }
        if source == .moveRegular { try requireQuit(.regular, "move it") }
        let profile = Profile(name: name.trimmingCharacters(in: .whitespaces), color: color)
        profiles.append(profile)
        return profile
    }

    func updateProfile(_ profile: Profile) async throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { throw ServiceError("Profile not found.") }
        if profiles[index].color != profile.color { try requireQuit(.profile(profile.id), "change its color") }
        profiles[index] = profile
    }

    func deleteProfile(id: UUID) async throws {
        try requireQuit(.profile(id), "delete it")
        await pretend()
        profiles.removeAll { $0.id == id }
        dock.remove(id)
    }

    func rebuildApp(id: UUID) async throws {
        try requireQuit(.profile(id), "rebuild it")
        await pretend()
    }

    func appURL(for profile: Profile) -> URL { paths.appURL(forName: profile.name) }

    // MARK: Instances
    func runningInstances() async -> [ClaudeInstance] {
        running.map { target, pid in
            let kind: InstanceKind
            let dir: URL
            switch target {
            case .regular: kind = .regular; dir = paths.regularClaudeDir
            case .profile(let id): kind = .profile(id); dir = paths.dataDir(for: id)
            }
            return ClaudeInstance(pid: pid, kind: kind, dataDir: dir, isFrontmost: front == target)
        }.sorted { $0.pid < $1.pid }
    }

    func lastActive(_ target: ClaudeTarget) -> Date? { lastActiveDates[target] }

    func open(_ target: ClaudeTarget) async throws {
        if running[target] == nil {
            await pretend()
            nextPid += 1
            running[target] = nextPid
        }
        front = target
        lastActiveDates[target] = .now
    }

    func bringToFront(_ target: ClaudeTarget) async throws {
        guard running[target] != nil else { throw ServiceError("It isn't running.") }
        front = target
        lastActiveDates[target] = .now
    }

    func quit(_ target: ClaudeTarget) async throws {
        await pretend()
        running[target] = nil
        if front == target { front = nil }
    }

    func accountID(for target: ClaudeTarget) -> String? {
        switch target {
        case .regular: return "acct-regular"
        case .profile(let id):
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
            return index < 2 ? "acct-\(index)" : nil
        }
    }

    func claudeDesktop() -> ClaudeDesktopInfo? {
        ClaudeDesktopInfo(appURL: URL(filePath: "/Applications/Claude.app"), version: "1.0.0 (demo)")
    }

    // MARK: Usage
    func usage(for target: ClaudeTarget) -> PlanUsageInfo {
        switch target {
        case .regular: return PlanUsageInfo(fiveHour: 12, weekly: 41, updatedAt: .now.addingTimeInterval(-900))
        case .profile(let id):
            switch profiles.firstIndex(where: { $0.id == id }) {
            case 0: return PlanUsageInfo(fiveHour: 83, weekly: 57, updatedAt: .now.addingTimeInterval(-300))
            case 1: return PlanUsageInfo(fiveHour: 97, weekly: 88, updatedAt: .now.addingTimeInterval(-60))
            default: return .unknown
            }
        }
    }

    // MARK: Switching
    func isInDock(_ profile: Profile) -> Bool { dock.contains(profile.id) }
    func setInDock(_ inDock: Bool, profile: Profile) async throws {
        await pretend()
        if inDock { dock.insert(profile.id) } else { dock.remove(profile.id) }
    }
    func isOnDesktop(_ profile: Profile) -> Bool { profiles.first { $0.id == profile.id }?.desktopShortcut ?? false }
    func setDesktopShortcut(_ enabled: Bool, profile: Profile) async throws {
        mutate(profile.id) { $0.desktopShortcut = enabled }
    }
    func setHotKey(_ spec: HotKeySpec?, profile: Profile) async throws {
        if let spec, profiles.contains(where: { $0.id != profile.id && $0.hotKey == spec }) {
            throw ServiceError("Another profile already uses this shortcut.")
        }
        mutate(profile.id) { $0.hotKey = spec }
    }

    // MARK: Terminal
    func terminalCommandName(for profile: Profile) -> String {
        let slug = profile.name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return "claude-\(slug)"
    }
    func setTerminalCommand(_ enabled: Bool, profile: Profile) async throws {
        await pretend()
        mutate(profile.id) { $0.terminalCommand = enabled }
    }

    // MARK: Bring over
    func importPreview(profile: Profile) async throws -> ImportPreview {
        try requireQuit(.profile(profile.id), "import")
        await pretend()
        return ImportPreview(items: [
            ImportItem(kind: .mcpServer, name: "filesystem"),
            ImportItem(kind: .mcpServer, name: "github"),
            ImportItem(kind: .extensionItem, name: "Desktop Commander"),
            ImportItem(kind: .developerSettings, name: "developer_settings.json"),
        ], alreadyPresent: 2)
    }
    func executeImport(_ preview: ImportPreview, profile: Profile) async throws -> Int {
        try requireQuit(.profile(profile.id), "import")
        await pretend()
        return preview.items.count
    }
    func syncPreview(profile: Profile, direction: SyncDirection) async throws -> SyncPreview {
        try requireQuit(.profile(profile.id), "sync")
        try requireQuit(.regular, "sync")
        await pretend()
        let same = accountID(for: .profile(profile.id)) == accountID(for: .regular)
        let dir: SyncDirection = same ? .both : (direction == .both ? .regularToProfile : direction)
        var items: [SyncItem] = []
        if dir != .profileToRegular {
            items += [
                SyncItem(id: "s1", title: "Refactor importer", cwd: "~/Code/Inventory", action: .copyToProfile, lastActivity: .now.addingTimeInterval(-3_600)),
                SyncItem(id: "s2", title: "Fix deploy script", cwd: "~/Code/Website", action: .updateProfile, lastActivity: .now.addingTimeInterval(-86_400)),
            ]
        }
        if dir != .regularToProfile {
            items.append(SyncItem(id: "s3", title: "OTA retry logic", cwd: "~/Code/Firmware", action: .copyToRegular, lastActivity: .now.addingTimeInterval(-7_200)))
        }
        return SyncPreview(sameAccount: same, direction: dir, items: items, unchanged: 14)
    }
    func executeSync(_ preview: SyncPreview, profile: Profile) async throws -> Int {
        await pretend()
        return preview.items.count
    }

    // MARK: Storage
    func storage(for target: ClaudeTarget) async -> StorageInfo {
        switch target {
        case .regular: StorageInfo(dataBytes: 2_400_000_000, cacheBytes: 310_000_000)
        case .profile: StorageInfo(dataBytes: 845_000_000, cacheBytes: 120_000_000)
        }
    }
    func clearCache(_ target: ClaudeTarget) async throws {
        try requireQuit(target, "clear its cache")
        await pretend()
    }
    func exportBackup(profile: Profile, to destination: URL) async throws {
        try requireQuit(.profile(profile.id), "export a backup")
        await pretend()
    }
    func regularClaudeHasData() -> Bool { true }

    // MARK: Memory
    func memoryOverview() async throws -> MemoryOverview { memory }
    func memoryConflicts(notes: [MemoryNoteInfo], project: MemoryProjectInfo) -> [String] {
        let existing = Set(project.notes.map(\.fileName))
        return notes.filter { $0.projectID != project.id && existing.contains($0.fileName) }.map(\.fileName)
    }
    func copyNotes(_ notes: [MemoryNoteInfo], to project: MemoryProjectInfo, policy: MemoryConflictPolicy) async throws -> MemoryOpResult {
        await pretend()
        let conflicts = Set(memoryConflicts(notes: notes, project: project))
        let candidates = notes.filter { $0.projectID != project.id }
        guard let index = memory.projects.firstIndex(where: { $0.id == project.id }) else { throw ServiceError("Project not found.") }
        var result = MemoryOpResult(written: 0, replaced: 0, skipped: notes.count - candidates.count)
        for note in candidates {
            var copy = note
            copy.projectID = project.id
            if conflicts.contains(note.fileName) {
                switch policy {
                case .skip: result.skipped += 1; continue
                case .replace: result.replaced += 1; memory.projects[index].notes.removeAll { $0.fileName == note.fileName }
                case .keepBoth: copy.fileName = note.fileName.replacingOccurrences(of: ".md", with: "-2.md"); copy.title += "-2"
                }
            }
            memory.projects[index].notes.append(copy)
            result.written += 1
        }
        return result
    }
    func makeGeneralRules(_ notes: [MemoryNoteInfo]) async throws -> MemoryOpResult {
        await pretend()
        memory.generalRulesLineCount = (memory.generalRulesLineCount ?? 0) + notes.count * 6
        return MemoryOpResult(written: notes.count, replaced: 0, skipped: 0)
    }

    // MARK: Finder (no-ops in the mock)
    func revealInFinder(_ url: URL) {}
    func openFolder(_ url: URL) {}
    func openInEditor(_ url: URL) {}

    // MARK: Settings
    func loadSettings() -> AppSettings { settings }
    func saveSettings(_ settings: AppSettings) async throws { self.settings = settings }

    // MARK: Links
    func route(_ url: URL, to target: ClaudeTarget) async throws {
        try await open(target)
    }

    private func mutate(_ id: UUID, _ change: (inout Profile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[index])
    }
}
