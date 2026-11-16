import CMACore
import CryptoKit
import Foundation

public enum BundleBuilderError: Error, Equatable {
    case agentMissing(String)
    case signFailed(String)
    case verifyFailed(String)
}

/// Builds `Claude (<Name>).app` profile bundles: stage in `Build/`, sign ad-hoc, verify, swap into the apps dir, register.
public struct BundleBuilder: Sendable {
    public static let defaultCodesign = URL(fileURLWithPath: "/usr/bin/codesign")
    public static let defaultLSRegister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")

    public let paths: AppPaths
    public let agentBinary: URL
    public let codesign: URL
    /// nil → skip LaunchServices registration (tests).
    public let lsregister: URL?
    public let appVersion: String

    public init(paths: AppPaths, agentBinary: URL, codesign: URL = BundleBuilder.defaultCodesign,
                lsregister: URL? = BundleBuilder.defaultLSRegister, appVersion: String = "1.0") {
        self.paths = paths; self.agentBinary = agentBinary; self.codesign = codesign
        self.lsregister = lsregister; self.appVersion = appVersion
    }

    /// The agent shipped inside the manager app (`Contents/Resources/ProfileAgent`).
    public static func bundledAgent(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: ProfileInfoPlist.executableName, withExtension: nil)
    }

    public static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func agentHash() throws -> String {
        guard FileManager.default.isReadableFile(atPath: agentBinary.path) else { throw BundleBuilderError.agentMissing(agentBinary.path) }
        return try Self.sha256(of: agentBinary)
    }

    public func appURL(for profile: Profile) -> URL { paths.appURL(forName: profile.name) }

    public func installedPlist(for profile: Profile) -> ProfileInfoPlist? { ProfileInfoPlist.read(appURL: appURL(for: profile)) }

    /// Missing, stale agent/builder, or settings in the plist differ from the profile.
    public func needsRebuild(_ profile: Profile) throws -> Bool {
        let installed = installedPlist(for: profile)
        if ProfileInfoPlist.isStale(installed, agentHash: try agentHash()) { return true }
        return installed?.differs(from: profile, paths: paths) ?? true
    }

    /// Builds (or rebuilds) the profile app. `previousAppURL` (e.g. before a rename) is removed after the swap.
    @discardableResult
    public func build(_ profile: Profile, previousAppURL: URL? = nil) async throws -> URL {
        let fm = FileManager.default
        let hash = try agentHash()
        let stageRoot = paths.buildDir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { if (try? SafePath.require(stageRoot, within: [paths.buildDir])) != nil { try? fm.removeItem(at: stageRoot) } }
        let dest = appURL(for: profile)
        let staged = stageRoot.appending(path: dest.lastPathComponent, directoryHint: .isDirectory)
        let contents = staged.appending(path: "Contents", directoryHint: .isDirectory)
        let macOS = contents.appending(path: "MacOS", directoryHint: .isDirectory)
        let resources = contents.appending(path: "Resources", directoryHint: .isDirectory)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let plist = try ProfileInfoPlist.make(profile: profile, paths: paths, agentHash: hash, appVersion: appVersion)
        try AtomicFile.write(plist, to: contents.appending(path: "Info.plist"))
        try AtomicFile.write(Data("APPL????".utf8), to: contents.appending(path: "PkgInfo"))
        let exe = macOS.appending(path: ProfileInfoPlist.executableName)
        try fm.copyItem(at: agentBinary, to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try IconRenderer.writeICNS(letter: profile.name, color: profile.color,
                                   to: resources.appending(path: "\(ProfileInfoPlist.iconFileName).icns"))
        Self.stripExtendedAttributes(staged)

        let sign = try await Subprocess.run(codesign, ["--force", "--sign", "-", "--timestamp=none", staged.path])
        guard sign.succeeded else { throw BundleBuilderError.signFailed(sign.stderrString) }
        let verify = try await Subprocess.run(codesign, ["--verify", "--strict", staged.path])
        guard verify.succeeded else { throw BundleBuilderError.verifyFailed(verify.stderrString) }

        try fm.createDirectory(at: paths.appsDir, withIntermediateDirectories: true)
        try SafePath.require(dest, within: [paths.appsDir])
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staged, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: staged, to: dest)
        }
        // Case-only rename on a case-insensitive volume: the "previous" app IS the new one. Fix the name's case
        // in place instead of deleting it.
        try Self.matchNameCase(dest)
        if let previousAppURL, previousAppURL.standardizedFileURL != dest.standardizedFileURL,
           fm.fileExists(atPath: previousAppURL.path), !Self.sameItem(previousAppURL, dest) {
            try await remove(appURL: previousAppURL)
        }
        if let lsregister { _ = try? await Subprocess.run(lsregister, ["-f", dest.path]) }
        return dest
    }

    /// Unregisters and deletes a profile app inside the apps dir.
    public func remove(appURL: URL) async throws {
        try SafePath.require(appURL, within: [paths.appsDir])
        guard FileManager.default.fileExists(atPath: appURL.path) else { return }
        if let lsregister { _ = try? await Subprocess.run(lsregister, ["-u", appURL.path]) }
        try FileManager.default.removeItem(at: appURL)
    }

    public func remove(_ profile: Profile) async throws {
        try await remove(appURL: appURL(for: profile))
        // Also apps left under an older name (e.g. an interrupted rename).
        for u in installedApps(profileID: profile.id) { try await remove(appURL: u) }
    }

    /// Every app in the apps dir whose Info.plist belongs to `profileID`, under any name.
    public func installedApps(profileID: UUID) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.appsDir.path)) ?? []
        return names.filter { $0.hasSuffix(".app") }.sorted()
            .map { paths.appsDir.appending(path: $0, directoryHint: .isDirectory) }
            .filter { ProfileInfoPlist.read(appURL: $0)?.profileID == profileID }
    }

    /// Removes apps for `profile` that aren't its current app (left by an interrupted rename).
    public func removeStaleApps(for profile: Profile) async throws {
        let current = appURL(for: profile)
        for u in installedApps(profileID: profile.id) where !Self.sameItem(u, current) {
            try await remove(appURL: u)
        }
    }

    /// Same file system object (device + inode); false if either is missing.
    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0, lstat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// If `url` exists on disk under a different letter case, renames it to exactly `url`'s name.
    static func matchNameCase(_ url: URL) throws {
        let dir = url.deletingLastPathComponent(), want = url.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard !names.contains(want),
              let actual = names.first(where: { $0.caseInsensitiveCompare(want) == .orderedSame }) else { return }
        let from = dir.appending(path: actual)
        guard sameItem(from, url) else { return }
        guard Darwin.rename(from.path, url.path) == 0 else { throw BundleBuilderError.verifyFailed("rename: \(errno)") }
    }

    /// codesign rejects bundles carrying Finder info / resource forks.
    static func stripExtendedAttributes(_ root: URL) {
        func strip(_ path: String) {
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return }
            var buf = [CChar](repeating: 0, count: size)
            let n = listxattr(path, &buf, size, XATTR_NOFOLLOW)
            guard n > 0 else { return }
            let names = buf[0..<n].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            for name in names { removexattr(path, name, XATTR_NOFOLLOW) }
        }
        strip(root.path)
        if let e = FileManager.default.enumerator(atPath: root.path) {
            for case let rel as String in e { strip(root.appending(path: rel).path) }
        }
    }
}
