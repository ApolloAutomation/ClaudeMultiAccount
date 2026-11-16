import Foundation

/// Layout of a Claude Desktop user-data-dir (regular or profile). Read-only helpers.
public struct ClaudeDataDir: Sendable, Equatable {
    public let url: URL
    public init(_ url: URL) { self.url = url }

    public var configJSON: URL { url.appending(path: "config.json") }
    public var planUsageJSON: URL { url.appending(path: "plan-usage-history.json") }
    public var sessionsDir: URL { url.appending(path: "claude-code-sessions", directoryHint: .isDirectory) }
    public var desktopConfigJSON: URL { url.appending(path: "claude_desktop_config.json") }
    public var developerSettingsJSON: URL { url.appending(path: "developer_settings.json") }
    public var extensionsInstallationsJSON: URL { url.appending(path: "extensions-installations.json") }
    public var extensionsDir: URL { url.appending(path: "Claude Extensions", directoryHint: .isDirectory) }
    public var extensionsSettingsDir: URL { url.appending(path: "Claude Extensions Settings", directoryHint: .isDirectory) }

    public var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Decodes only `lastKnownAccountUuid`; every other key (including oauth caches) is skipped by the decoder.
    private struct AccountProbe: Decodable {
        let lastKnownAccountUuid: String?
        enum CodingKeys: String, CodingKey { case lastKnownAccountUuid }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastKnownAccountUuid = try? c.decodeIfPresent(String.self, forKey: .lastKnownAccountUuid)
        }
    }

    public static func accountUUID(fromConfig data: Data) -> String? {
        guard let probe = try? JSONDecoder().decode(AccountProbe.self, from: data),
              let s = probe.lastKnownAccountUuid, UUID(uuidString: s) != nil else { return nil }
        return s.lowercased()
    }

    public func accountUUID() -> String? {
        guard let data = try? Data(contentsOf: configJSON) else { return nil }
        return Self.accountUUID(fromConfig: data)
    }

    public func planUsageSamples() -> [PlanUsageSample] {
        guard let data = try? Data(contentsOf: planUsageJSON) else { return [] }
        return PlanUsage.parse(data)
    }
}
