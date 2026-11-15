import Foundation

public enum ProfileColor: String, Codable, CaseIterable, Sendable {
    case orange, blue, green, purple, pink, red, teal, gray
    public var displayName: String { rawValue.capitalized }
}

public enum BorderWidth: Int, Codable, CaseIterable, Sendable {
    case thin = 2, medium = 4, thick = 6
    public var displayName: String {
        switch self { case .thin: "Thin"; case .medium: "Medium"; case .thick: "Thick" }
    }
}

/// Carbon key code + Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
public struct HotKeySpec: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
}

public struct Profile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var bundleIdentifier: String
    public var createdAt: Date
    public var showBorder: Bool
    public var borderWidth: BorderWidth
    public var terminalCommand: Bool
    public var desktopShortcut: Bool
    public var hotKey: HotKeySpec?
    /// Optional CLAUDE_CONFIG_DIR override passed to Claude Desktop.
    public var claudeConfigDir: String?

    public init(id: UUID = UUID(), name: String, color: ProfileColor, createdAt: Date = Date(),
                showBorder: Bool = true, borderWidth: BorderWidth = .thin, terminalCommand: Bool = false,
                desktopShortcut: Bool = false, hotKey: HotKeySpec? = nil, claudeConfigDir: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.bundleIdentifier = "\(AppPaths.bundleID).profile.\(id.uuidString.prefix(8).lowercased())"
        self.createdAt = createdAt
        self.showBorder = showBorder
        self.borderWidth = borderWidth
        self.terminalCommand = terminalCommand
        self.desktopShortcut = desktopShortcut
        self.hotKey = hotKey
        self.claudeConfigDir = claudeConfigDir
    }
}
