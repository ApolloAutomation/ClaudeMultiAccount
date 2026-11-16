import Foundation

public struct AppSettings: Codable, Sendable, Equatable {
    public var onboardingCompleted: Bool
    public var linkRoutingEnabled: Bool
    public var musicPauseEnabled: Bool
    public var menuBarLetter: Bool
    public var launchAtLogin: Bool

    public init(onboardingCompleted: Bool = false, linkRoutingEnabled: Bool = false, musicPauseEnabled: Bool = false,
                menuBarLetter: Bool = false, launchAtLogin: Bool = false) {
        self.onboardingCompleted = onboardingCompleted
        self.linkRoutingEnabled = linkRoutingEnabled
        self.musicPauseEnabled = musicPauseEnabled
        self.menuBarLetter = menuBarLetter
        self.launchAtLogin = launchAtLogin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        linkRoutingEnabled = try c.decodeIfPresent(Bool.self, forKey: .linkRoutingEnabled) ?? false
        musicPauseEnabled = try c.decodeIfPresent(Bool.self, forKey: .musicPauseEnabled) ?? false
        menuBarLetter = try c.decodeIfPresent(Bool.self, forKey: .menuBarLetter) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }
}

public struct RuntimeState: Codable, Sendable, Equatable {
    /// Keyed by profile UUID string.
    public var lastActiveAt: [String: Date]
    public var settings: AppSettings

    public init(lastActiveAt: [String: Date] = [:], settings: AppSettings = AppSettings()) {
        self.lastActiveAt = lastActiveAt
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastActiveAt = try c.decodeIfPresent([String: Date].self, forKey: .lastActiveAt) ?? [:]
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }

    public func lastActive(_ id: UUID) -> Date? { lastActiveAt[id.uuidString] }

    public var lastActiveByID: [UUID: Date] {
        var out: [UUID: Date] = [:]
        for (k, v) in lastActiveAt { if let id = UUID(uuidString: k) { out[id] = v } }
        return out
    }
}

/// Owns state.json. Corrupt or missing file → defaults.
public actor RuntimeStateStore {
    public let url: URL
    private var cache: RuntimeState?

    public init(paths: AppPaths) { url = paths.stateJSON }
    public init(url: URL) { self.url = url }

    /// Synchronous read for callers that cannot await (e.g. building initial UI state). Missing/damaged → defaults.
    public static func load(url: URL) -> RuntimeState {
        (try? Data(contentsOf: url)).flatMap { try? CMAJSON.decoder().decode(RuntimeState.self, from: $0) } ?? RuntimeState()
    }

    public func state() -> RuntimeState {
        if let cache { return cache }
        let s = (try? Data(contentsOf: url)).flatMap { try? CMAJSON.decoder().decode(RuntimeState.self, from: $0) } ?? RuntimeState()
        cache = s
        return s
    }

    public func settings() -> AppSettings { state().settings }

    public func updateSettings(_ mutate: @Sendable (inout AppSettings) -> Void) throws {
        var s = state()
        mutate(&s.settings)
        try save(s)
    }

    public func markActive(_ id: UUID, at date: Date = Date()) throws {
        var s = state()
        s.lastActiveAt[id.uuidString] = date
        try save(s)
    }

    public func forget(_ id: UUID) throws {
        var s = state()
        s.lastActiveAt[id.uuidString] = nil
        try save(s)
    }

    private func save(_ s: RuntimeState) throws {
        try AtomicFile.write(CMAJSON.encoder().encode(s), to: url, permissions: 0o600)
        cache = s
    }
}
