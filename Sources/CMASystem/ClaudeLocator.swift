import AppKit
import CMACore
import Foundation

public struct ClaudeInstallation: Sendable, Equatable {
    public let url: URL
    public let version: String?
    public let build: String?
    public var displayVersion: String {
        switch (version, build) {
        case let (v?, b?) where b != v: "\(v) (\(b))"
        case let (v?, _): v
        default: "unknown"
        }
    }
}

/// Finds Claude Desktop: /Applications, ~/Applications, then LaunchServices by bundle id.
public struct ClaudeLocator: Sendable {
    public let paths: AppPaths
    public init(paths: AppPaths = AppPaths()) { self.paths = paths }

    public var candidates: [URL] {
        [URL(filePath: "/Applications/Claude.app", directoryHint: .isDirectory),
         paths.home.appending(path: "Applications/Claude.app", directoryHint: .isDirectory)]
    }

    public func locate() -> ClaudeInstallation? {
        for url in candidates where Self.isClaude(url) { return Self.installation(at: url) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppPaths.claudeBundleID),
           Self.isClaude(url) {
            return Self.installation(at: url)
        }
        return nil
    }

    public static func info(at appURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: appURL.appending(path: "Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    public static func isClaude(_ url: URL) -> Bool {
        (info(at: url)?["CFBundleIdentifier"] as? String) == AppPaths.claudeBundleID
    }

    public static func installation(at url: URL) -> ClaudeInstallation {
        let d = info(at: url)
        return ClaudeInstallation(url: url,
                                  version: d?["CFBundleShortVersionString"] as? String,
                                  build: d?["CFBundleVersion"] as? String)
    }
}
