import Foundation

public enum SafePathError: Error, Equatable {
    case outsideAllowedRoots(String)
    case isRoot(String)
    case invalidComponent(String)
}

/// Guards every remove/replace/trash: the target must be strictly inside one of the allowed roots.
public enum SafePath {
    /// Resolves symlinks of the parent (not the leaf, which may itself be a link we intend to replace).
    public static func canonical(_ url: URL) -> String {
        let std = url.standardizedFileURL
        let leaf = std.lastPathComponent
        let parent = std.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appending(path: leaf).standardizedFileURL.path
    }

    private static func canonicalRoot(_ url: URL) -> String {
        var p = url.standardizedFileURL.resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    @discardableResult
    public static func require(_ url: URL, within roots: [URL]) throws -> URL {
        let raw = url.path
        let leaf = url.lastPathComponent
        if leaf.isEmpty || leaf == "." || leaf == ".." || raw.contains("\0") {
            throw SafePathError.invalidComponent(raw)
        }
        if url.pathComponents.contains("..") { throw SafePathError.invalidComponent(raw) }
        let target = canonical(url).lowercased()
        for root in roots {
            let r = canonicalRoot(root).lowercased()
            if target == r { throw SafePathError.isRoot(raw) }
            let prefix = r == "/" ? "/" : r + "/"
            if r != "/" && target.hasPrefix(prefix) { return url }
        }
        throw SafePathError.outsideAllowedRoots(raw)
    }

    /// Roots the app may mutate inside.
    public static func defaultRoots(_ paths: AppPaths) -> [URL] {
        [paths.appSupport, paths.appsDir, paths.regularClaudeDir.appending(path: "claude-code-sessions", directoryHint: .isDirectory),
         paths.claudeConfigDir, paths.localBinDir, paths.desktopDir]
    }

    @discardableResult
    public static func require(_ url: URL, in paths: AppPaths) throws -> URL {
        try require(url, within: defaultRoots(paths))
    }

    /// True if `name` is a single safe path component (no separators, not . or .., no NUL, not empty).
    public static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && !name.contains("\\")
    }
}
