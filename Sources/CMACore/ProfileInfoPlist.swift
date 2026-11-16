import Foundation

/// The CMA* keys of a generated profile app's Info.plist.
public struct ProfileInfoPlist: Sendable, Equatable {
    public static let builderVersion = 1
    public static let executableName = "ProfileAgent"
    public static let iconFileName = "ProfileIcon"
    public static let minimumSystemVersion = "26.0"

    public enum Key {
        public static let profileID = "CMAProfileID"
        public static let profileName = "CMAProfileName"
        public static let userDataDir = "CMAUserDataDir"
        public static let color = "CMAColor"
        public static let showBorder = "CMAShowBorder"
        public static let borderWidth = "CMABorderWidth"
        public static let claudeConfigDir = "CMAClaudeConfigDir"
        public static let agentHash = "CMAAgentHash"
        public static let builderVersion = "CMABuilderVersion"
    }

    public var profileID: UUID
    public var profileName: String
    public var userDataDir: String
    public var color: ProfileColor
    public var showBorder: Bool
    public var borderWidth: BorderWidth
    public var claudeConfigDir: String?
    public var agentHash: String
    public var builderVersion: Int
    public var bundleIdentifier: String

    public init(profile: Profile, paths: AppPaths, agentHash: String, builderVersion: Int = ProfileInfoPlist.builderVersion) {
        profileID = profile.id
        profileName = profile.name
        userDataDir = paths.dataDir(for: profile.id).path
        color = profile.color
        showBorder = profile.showBorder
        borderWidth = profile.borderWidth
        claudeConfigDir = profile.claudeConfigDir
        self.agentHash = agentHash
        self.builderVersion = builderVersion
        bundleIdentifier = Slug.bundleIdentifier(for: profile.id)
    }

    public init?(dictionary d: [String: Any]) {
        guard let idS = d[Key.profileID] as? String, let id = UUID(uuidString: idS),
              let name = d[Key.profileName] as? String,
              let dir = d[Key.userDataDir] as? String, !dir.isEmpty else { return nil }
        profileID = id
        profileName = name
        userDataDir = dir
        color = (d[Key.color] as? String).flatMap(ProfileColor.init(rawValue:)) ?? .orange
        showBorder = (d[Key.showBorder] as? Bool) ?? true
        borderWidth = (d[Key.borderWidth] as? Int).flatMap(BorderWidth.init(rawValue:)) ?? .thin
        let cfg = d[Key.claudeConfigDir] as? String
        claudeConfigDir = (cfg?.isEmpty ?? true) ? nil : cfg
        agentHash = (d[Key.agentHash] as? String) ?? ""
        builderVersion = (d[Key.builderVersion] as? Int) ?? 0
        bundleIdentifier = (d["CFBundleIdentifier"] as? String) ?? Slug.bundleIdentifier(for: id)
    }

    public static func parse(_ data: Data) -> ProfileInfoPlist? {
        guard let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return ProfileInfoPlist(dictionary: d)
    }

    public static func read(appURL: URL) -> ProfileInfoPlist? {
        guard let data = try? Data(contentsOf: appURL.appending(path: "Contents/Info.plist")) else { return nil }
        return parse(data)
    }

    /// Full Info.plist dictionary for the profile app.
    public func dictionary(appVersion: String = "1.0") -> [String: Any] {
        var d: [String: Any] = [
            "CFBundleExecutable": Self.executableName,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": Slug.appName(profileName),
            "CFBundleDisplayName": Slug.appName(profileName),
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleIconFile": Self.iconFileName,
            "CFBundleShortVersionString": appVersion,
            "CFBundleVersion": appVersion,
            "CFBundleDevelopmentRegion": "en",
            "LSMinimumSystemVersion": Self.minimumSystemVersion,
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            Key.profileID: profileID.uuidString,
            Key.profileName: profileName,
            Key.userDataDir: userDataDir,
            Key.color: color.rawValue,
            Key.showBorder: showBorder,
            Key.borderWidth: borderWidth.rawValue,
            Key.agentHash: agentHash,
            Key.builderVersion: builderVersion,
        ]
        if let claudeConfigDir, !claudeConfigDir.isEmpty { d[Key.claudeConfigDir] = claudeConfigDir }
        return d
    }

    public func data(appVersion: String = "1.0") throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary(appVersion: appVersion), format: .xml, options: 0)
    }

    public static func make(profile: Profile, paths: AppPaths, agentHash: String, appVersion: String = "1.0") throws -> Data {
        try ProfileInfoPlist(profile: profile, paths: paths, agentHash: agentHash).data(appVersion: appVersion)
    }

    /// Stale = missing, agent hash differs, or builder version differs → rebuild.
    public static func isStale(_ installed: ProfileInfoPlist?, agentHash: String, builderVersion: Int = ProfileInfoPlist.builderVersion) -> Bool {
        guard let installed else { return true }
        return installed.agentHash != agentHash || installed.builderVersion != builderVersion
    }

    /// True if the installed plist no longer reflects the profile's settings.
    public func differs(from profile: Profile, paths: AppPaths) -> Bool {
        var want = ProfileInfoPlist(profile: profile, paths: paths, agentHash: agentHash, builderVersion: builderVersion)
        want.bundleIdentifier = bundleIdentifier
        return want != self || bundleIdentifier != Slug.bundleIdentifier(for: profile.id)
    }
}
