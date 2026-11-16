import Foundation
import CMACore

/// Every side effect the manager UI needs. The UI only talks to this protocol.
/// `MockProfileServices` backs it with sample data; `LiveProfileServices` is the CMASystem-backed production implementation.
/// Implementations run on the main actor and hop to their own actors/queues for slow work.
@MainActor
protocol ProfileServices: AnyObject {
    var paths: AppPaths { get }

    /// Launch-time work (journal recovery, hotkeys, link routing, stale app rebuilds). Called once.
    func start()

    // MARK: Profiles
    func loadProfiles() async throws -> [Profile]
    /// Returns a user-facing error message, or nil when the name is acceptable.
    func validateName(_ name: String, excluding id: UUID?) -> String?
    func createProfile(name: String, color: ProfileColor, source: NewProfileSource) async throws -> Profile
    /// Persist changes (rename, color, border). Implementations rebuild/rename the app as needed.
    func updateProfile(_ profile: Profile) async throws
    func deleteProfile(id: UUID) async throws
    func rebuildApp(id: UUID) async throws
    func appURL(for profile: Profile) -> URL

    // MARK: Instances
    func runningInstances() async -> [ClaudeInstance]
    func lastActive(_ target: ClaudeTarget) -> Date?
    /// Opens the profile app (or regular Claude) or brings it to the front if it is already running.
    func open(_ target: ClaudeTarget) async throws
    func bringToFront(_ target: ClaudeTarget) async throws
    func quit(_ target: ClaudeTarget) async throws
    /// Account UUID the data dir was last signed in to (`config.json.lastKnownAccountUuid`).
    func accountID(for target: ClaudeTarget) -> String?
    func claudeDesktop() -> ClaudeDesktopInfo?

    // MARK: Usage
    func usage(for target: ClaudeTarget) -> PlanUsageInfo

    // MARK: Switching
    func isInDock(_ profile: Profile) -> Bool
    func setInDock(_ inDock: Bool, profile: Profile) async throws
    func isOnDesktop(_ profile: Profile) -> Bool
    func setDesktopShortcut(_ enabled: Bool, profile: Profile) async throws
    /// Registers (or clears with nil) a global hotkey; throws if the combination is taken.
    func setHotKey(_ spec: HotKeySpec?, profile: Profile) async throws

    // MARK: Terminal command
    func terminalCommandName(for profile: Profile) -> String
    func setTerminalCommand(_ enabled: Bool, profile: Profile) async throws

    // MARK: Bring over from regular Claude
    func importPreview(profile: Profile) async throws -> ImportPreview
    func executeImport(_ preview: ImportPreview, profile: Profile) async throws -> Int
    func syncPreview(profile: Profile, direction: SyncDirection) async throws -> SyncPreview
    func executeSync(_ preview: SyncPreview, profile: Profile) async throws -> Int

    // MARK: Backup & storage
    func storage(for target: ClaudeTarget) async -> StorageInfo
    func clearCache(_ target: ClaudeTarget) async throws
    func exportBackup(profile: Profile, to destination: URL) async throws
    func regularClaudeHasData() -> Bool

    // MARK: Memory
    func memoryOverview() async throws -> MemoryOverview
    /// File names that already exist in the destination project.
    func memoryConflicts(notes: [MemoryNoteInfo], project: MemoryProjectInfo) -> [String]
    func copyNotes(_ notes: [MemoryNoteInfo], to project: MemoryProjectInfo, policy: MemoryConflictPolicy) async throws -> MemoryOpResult
    func makeGeneralRules(_ notes: [MemoryNoteInfo]) async throws -> MemoryOpResult

    // MARK: Finder
    func revealInFinder(_ url: URL)
    func openFolder(_ url: URL)
    func openInEditor(_ url: URL)

    // MARK: Settings
    func loadSettings() -> AppSettings
    func saveSettings(_ settings: AppSettings) async throws

    // MARK: Links
    /// claude:// links that need the user to pick a target (more than one instance running).
    var linkRequests: AsyncStream<LinkRequest> { get }
    func route(_ url: URL, to target: ClaudeTarget) async throws
}

extension ProfileServices {
    func start() {}
}
