import Foundation
import CMACore

// UI-side value types. They mirror CMACore/CMASystem results so the UI does not depend on
// the timing of those modules; the real `ProfileServices` adapter maps into these.

/// A Claude Desktop instance the UI can act on.
enum ClaudeTarget: Hashable, Sendable {
    case regular
    case profile(UUID)
}

/// Sidebar destinations.
enum SidebarItem: Hashable, Sendable {
    case profile(UUID)
    case regular
    case memory
}

enum RunState: Equatable, Sendable {
    case notRunning
    case running
    case runningInFront

    var isRunning: Bool { self != .notRunning }

    var label: String {
        switch self {
        case .notRunning: "Ready"
        case .running: "Running"
        case .runningInFront: "Running, in front"
        }
    }
}

struct PlanUsageInfo: Equatable, Sendable {
    /// Percent used of the 5-hour window, nil when unknown or stale.
    var fiveHour: Double?
    /// Percent used of the weekly window, nil when unknown.
    var weekly: Double?
    var updatedAt: Date?

    static let unknown = PlanUsageInfo(fiveHour: nil, weekly: nil, updatedAt: nil)
}

enum UsageLevel: Sendable {
    case normal, warning, critical
    init(percent: Double) {
        if percent >= 95 { self = .critical } else if percent >= 80 { self = .warning } else { self = .normal }
    }
}

struct StorageInfo: Equatable, Sendable {
    var dataBytes: Int64?
    var cacheBytes: Int64?
    static let unknown = StorageInfo(dataBytes: nil, cacheBytes: nil)
}

struct ClaudeDesktopInfo: Equatable, Sendable {
    var appURL: URL
    var version: String
}

enum NewProfileSource: Hashable, Sendable {
    case empty
    case moveRegular
    case restore(URL)
}

enum ImportItemKind: String, Sendable {
    case mcpServer = "MCP server"
    case preference = "Preference"
    case setting = "Setting"
    case extensionItem = "Extension"
    case developerSettings = "Developer settings"

    var symbol: String {
        switch self {
        case .mcpServer: "server.rack"
        case .preference, .setting: "slider.horizontal.3"
        case .extensionItem: "puzzlepiece.extension"
        case .developerSettings: "hammer"
        }
    }
}

struct ImportItem: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(name)" }
    var kind: ImportItemKind
    var name: String
}

struct ImportPreview: Equatable, Sendable {
    var items: [ImportItem]
    /// How many candidate entries the profile already has (left untouched).
    var alreadyPresent: Int
}

enum SyncDirection: String, CaseIterable, Identifiable, Sendable {
    case both, regularToProfile, profileToRegular
    var id: String { rawValue }
}

enum SyncAction: Sendable {
    case copyToProfile, copyToRegular, updateProfile, updateRegular

    var label: String {
        switch self {
        case .copyToProfile: "Copy to profile"
        case .copyToRegular: "Copy to regular Claude"
        case .updateProfile: "Update in profile"
        case .updateRegular: "Update in regular Claude"
        }
    }
    var symbol: String {
        switch self {
        case .copyToProfile, .updateProfile: "arrow.right"
        case .copyToRegular, .updateRegular: "arrow.left"
        }
    }
}

struct SyncItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var cwd: String?
    var action: SyncAction
    var lastActivity: Date?
}

struct SyncPreview: Equatable, Sendable {
    /// Both sides are signed in to the same account (two-way allowed).
    var sameAccount: Bool
    var direction: SyncDirection
    var items: [SyncItem]
    /// Records identical on both sides or blocked by a deletion marker.
    var unchanged: Int
}

struct MemoryNoteInfo: Identifiable, Hashable, Sendable {
    /// "<projectID>/<fileName>"
    var id: String { "\(projectID)/\(fileName)" }
    var projectID: String
    var fileName: String
    var title: String
    var type: String?
    var summary: String?
    var url: URL
}

struct MemoryProjectInfo: Identifiable, Hashable, Sendable {
    /// The encoded directory name under ~/.claude/projects.
    var id: String
    var name: String
    var displayPath: String
    var notes: [MemoryNoteInfo]
}

struct MemoryOverview: Equatable, Sendable {
    var generalRulesURL: URL
    var generalRulesLineCount: Int?
    var projects: [MemoryProjectInfo]

    var noteCount: Int { projects.reduce(0) { $0 + $1.notes.count } }
}

enum MemoryConflictPolicy: Sendable {
    case replace, keepBoth, skip
}

struct MemoryOpResult: Equatable, Sendable {
    var written: Int
    var replaced: Int
    var skipped: Int

    var summary: String {
        var parts = ["\(written) written"]
        if replaced > 0 { parts.append("\(replaced) replaced (backed up)") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: ", ")
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var launchAtLogin = false
    var showLetterInMenuBar = false
    var routeLinks = false
    var pauseMusicWhileDictating = false
    var onboardingCompleted = false
}

struct LinkRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    var url: URL
    /// Running instances the link could go to.
    var candidates: [ClaudeTarget]
    /// Most recently active candidate.
    var preselected: ClaudeTarget?
}

struct ServiceError: LocalizedError, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
