import CMACore
import Foundation

public enum DesktopShortcutError: Error, Equatable {
    case foreignFileExists(String)
    case targetMissing(String)
}

/// Finder alias on the Desktop pointing at a profile app. Never overwrites or removes a file that isn't our alias.
public struct DesktopShortcut: Sendable {
    public let desktopDir: URL
    public let appsDir: URL

    public init(desktopDir: URL, appsDir: URL) { self.desktopDir = desktopDir; self.appsDir = appsDir }
    public init(paths: AppPaths) { self.init(desktopDir: paths.desktopDir, appsDir: paths.appsDir) }

    public func shortcutURL(forName name: String) -> URL { desktopDir.appending(path: Slug.appName(name)) }

    /// Path an alias file points to, read without resolving (works when the target is gone).
    public static func aliasTargetPath(_ url: URL) -> String? {
        guard let data = try? URL.bookmarkData(withContentsOf: url),
              let values = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data) else { return nil }
        return values.path
    }

    /// An alias pointing into our apps dir (or at `target`).
    public func isOurs(_ url: URL, target: URL? = nil) -> Bool {
        guard let p = Self.aliasTargetPath(url) else { return false }
        let std = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        if let target, std == target.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() { return true }
        let root = appsDir.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        return std.hasPrefix(root + "/")
    }

    public func exists(name: String) -> Bool {
        (try? shortcutURL(forName: name).checkResourceIsReachable()) == true
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: shortcutURL(forName: name).path)) != nil
    }

    @discardableResult
    public func create(target appURL: URL, name: String) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appURL.path) else { throw DesktopShortcutError.targetMissing(appURL.path) }
        let link = shortcutURL(forName: name)
        if exists(name: name) {
            guard isOurs(link, target: appURL) else { throw DesktopShortcutError.foreignFileExists(link.path) }
            try SafePath.require(link, within: [desktopDir])
            try fm.removeItem(at: link)
        }
        try fm.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        let data = try appURL.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: link)
        return link
    }

    /// Removes the alias only if it is ours. Returns false when nothing (of ours) was there.
    @discardableResult
    public func remove(name: String) throws -> Bool {
        let link = shortcutURL(forName: name)
        guard exists(name: name) else { return false }
        guard isOurs(link) else { throw DesktopShortcutError.foreignFileExists(link.path) }
        try SafePath.require(link, within: [desktopDir])
        try FileManager.default.removeItem(at: link)
        return true
    }
}
