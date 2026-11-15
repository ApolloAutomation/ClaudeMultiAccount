import Foundation

/// Every filesystem root the app touches. Built from an injected home so tests never see real user data.
public struct AppPaths: Sendable, Equatable {
    public static let appName = "Claude Multi Account"
    public static let bundleID = "com.apolloautomation.claudemultiaccount"
    public static let claudeBundleID = "com.anthropic.claudefordesktop"

    public let home: URL
    public let appSupport: URL
    public let profilesDir: URL
    public let cliDir: URL
    public let buildDir: URL
    public let backupsDir: URL
    public let locksDir: URL
    public let journalDir: URL
    public let appsDir: URL
    public let regularClaudeDir: URL
    public let claudeConfigDir: URL
    public let desktopDir: URL
    public let localBinDir: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                appSupportName: String = AppPaths.appName) {
        self.home = home
        let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        appSupport = support.appending(path: appSupportName, directoryHint: .isDirectory)
        profilesDir = appSupport.appending(path: "Profiles", directoryHint: .isDirectory)
        cliDir = appSupport.appending(path: "CLI", directoryHint: .isDirectory)
        buildDir = appSupport.appending(path: "Build", directoryHint: .isDirectory)
        backupsDir = appSupport.appending(path: "Backups", directoryHint: .isDirectory)
        locksDir = appSupport.appending(path: "Locks", directoryHint: .isDirectory)
        journalDir = appSupport.appending(path: "Journal", directoryHint: .isDirectory)
        appsDir = home.appending(path: "Applications/\(appSupportName)", directoryHint: .isDirectory)
        regularClaudeDir = support.appending(path: "Claude", directoryHint: .isDirectory)
        claudeConfigDir = home.appending(path: ".claude", directoryHint: .isDirectory)
        desktopDir = home.appending(path: "Desktop", directoryHint: .isDirectory)
        localBinDir = home.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    public var profilesJSON: URL { appSupport.appending(path: "profiles.json") }
    public var stateJSON: URL { appSupport.appending(path: "state.json") }
    public func dataDir(for id: UUID) -> URL { profilesDir.appending(path: id.uuidString, directoryHint: .isDirectory) }
    public func cliConfigDir(for id: UUID) -> URL { cliDir.appending(path: id.uuidString, directoryHint: .isDirectory) }
    /// `Claude (<Name>).app` inside the apps dir.
    public func appURL(forName name: String) -> URL { appsDir.appending(path: "Claude (\(name)).app", directoryHint: .isDirectory) }
}
