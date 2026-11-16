import Foundation
import Testing
@testable import CMACore
@testable import CMASystem

@Suite struct TerminalCommandInstallerTests {
    @Test func installsSeedsAndRefusesForeign() throws {
        let t = TempDir()
        t.write(".claude/CLAUDE.md", "rules")
        t.write(".claude/settings.json", "{}")
        try FileManager.default.createDirectory(at: t.url.appending(path: ".claude/projects"), withIntermediateDirectories: true)
        let inst = TerminalCommandInstaller(paths: t.paths, binDirs: [t.paths.localBinDir])
        let p = Profile(name: "Work Stuff", color: .blue)
        let u = try inst.install(p)
        #expect(u.lastPathComponent == Slug.terminalCommand(for: "Work Stuff"))
        let s = try String(contentsOf: u, encoding: .utf8)
        #expect(TerminalScript.isOwned(s, profileID: p.id))
        #expect(FileManager.default.isExecutableFile(atPath: u.path))
        let cli = t.paths.cliConfigDir(for: p.id)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: cli.appending(path: "CLAUDE.md").path)
                == t.paths.claudeConfigDir.appending(path: "CLAUDE.md").path)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: cli.appending(path: "skills").path)) == nil)
        #expect(inst.installedURL(p) == u)

        // Rename: old script removed, new one installed.
        var renamed = p; renamed.name = "Job"
        let u2 = try inst.install(renamed)
        #expect(!FileManager.default.fileExists(atPath: u.path))
        #expect(FileManager.default.fileExists(atPath: u2.path))

        // Foreign file is never overwritten or removed.
        let other = Profile(name: "Mine", color: .red)
        let foreign = t.write(".local/bin/claude-mine", "#!/bin/sh\necho hi\n")
        #expect(throws: TerminalCommandError.foreignFileExists(foreign.path)) { try inst.install(other) }
        try inst.uninstall(other)
        #expect(t.data(".local/bin/claude-mine") == Data("#!/bin/sh\necho hi\n".utf8))

        try inst.uninstall(renamed)
        #expect(!FileManager.default.fileExists(atPath: u2.path))
    }
}

final class MemoryDockStore: DockPreferencesStore, @unchecked Sendable {
    var apps: [Any] = [["tile-data": ["bundle-identifier": "com.apple.Safari"]]]
    func persistentApps() -> [Any] { apps }
    func setPersistentApps(_ apps: [Any]) throws { self.apps = apps }
}

@Suite struct DockEditorTests {
    @Test func addAndRemoveWithoutTouchingRealDock() throws {
        let store = MemoryDockStore()
        let d = DockEditor(store: store)
        let url = URL(fileURLWithPath: "/tmp/x/Claude (W).app", isDirectory: true)
        try d.add(appURL: url, label: "Claude (W)", bundleID: "com.x.profile.1")
        try d.add(appURL: url, label: "Claude (W)", bundleID: "com.x.profile.1")
        #expect(store.apps.count == 2)
        #expect(d.isInDock(bundleID: "com.x.profile.1"))
        try d.remove(bundleID: "com.x.profile.1")
        #expect(!d.isInDock(bundleID: "com.x.profile.1"))
        #expect(DockPlist.contains(store.apps, bundleID: "com.apple.Safari"))
    }
}

@Suite struct DesktopShortcutTests {
    @Test func aliasCreateReplaceRemoveAndForeignRefusal() throws {
        let t = TempDir()
        let app = t.paths.appURL(forName: "Work")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let ds = DesktopShortcut(paths: t.paths)
        let link = try ds.create(target: app, name: "Work")
        #expect(try link.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
        #expect(ds.isOurs(link, target: app))
        _ = try ds.create(target: app, name: "Work") // replace our own
        #expect(try ds.remove(name: "Work"))
        #expect(!ds.exists(name: "Work"))

        let foreign = t.write("Desktop/Claude (Home)", "not ours")
        let homeApp = t.paths.appURL(forName: "Home")
        try FileManager.default.createDirectory(at: homeApp, withIntermediateDirectories: true)
        #expect(throws: DesktopShortcutError.foreignFileExists(foreign.path)) { try ds.create(target: homeApp, name: "Home") }
        #expect(throws: DesktopShortcutError.foreignFileExists(foreign.path)) { try ds.remove(name: "Home") }
        #expect(t.data("Desktop/Claude (Home)") == Data("not ours".utf8))
    }
}

final class FakeRegistry: URLSchemeRegistry, @unchecked Sendable {
    let lock = NSLock()
    var current: URL?
    var sets = 0
    func handler(forScheme scheme: String) -> URL? { lock.withLock { current } }
    func setHandler(_ appURL: URL, forScheme scheme: String) async throws { lock.withLock { current = appURL; sets += 1 } }
}

@Suite @MainActor struct LinkHandlerRegistrationTests {
    @Test func reclaimsOnlyWhenLostAndHandsBack() async throws {
        let reg = FakeRegistry()
        let ours = URL(fileURLWithPath: "/tmp/ours.app"), claude = URL(fileURLWithPath: "/tmp/Claude.app")
        let l = LinkHandlerRegistration(registry: reg, ourAppURL: ours, claudeAppURL: { claude })
        await #expect(!l.reclaimIfNeeded()) // disabled
        try await l.enable()
        #expect(l.isOurs)
        await #expect(!l.reclaimIfNeeded())
        reg.lock.withLock { reg.current = claude } // Claude took it back on launch
        await #expect(l.reclaimIfNeeded())
        #expect(l.isOurs && l.reclaimCount == 1)
        try await l.disable()
        #expect(reg.handler(forScheme: "claude") == claude)
        await #expect(!l.reclaimIfNeeded())
    }
}

@Suite struct URLForwarderTests {
    @Test func buildsGetURLEventAndRejectsInvalid() throws {
        let u = URL(string: "claude://claude.ai/new?q=1")!
        let e = URLForwarder.event(for: u, pid: 1)
        #expect(URLForwarder.url(fromGetURLEvent: e) == u)
        #expect(throws: URLForwarderError.invalidURL) { try URLForwarder.forward(URL(string: "https://x")!, toPID: 1) }
    }
}

@Suite struct HotKeyTests {
    @Test func requiresModifier() {
        #expect(HotKeyCenter.validate(HotKeySpec(keyCode: 0, modifiers: 0)) == .noModifier)
        #expect(HotKeyCenter.validate(HotKeySpec(keyCode: 0, modifiers: 256)) == nil)
    }
}
