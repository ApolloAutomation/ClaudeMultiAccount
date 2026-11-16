import Foundation
import Testing
@testable import CMACore
@testable import CMASystem

/// Regression tests for the security review fixes (temp dirs only).
@Suite struct SecurityFixTests {
    // M1: an archive index that doesn't parse is never rewritten (and never wiped).
    @Test func unreadableArchiveIndexIsLeftAlone() throws {
        let t = TempDir()
        let pid = UUID()
        let reg = "Library/Application Support/Claude/claude-code-sessions/acc/org"
        let prof = "Library/Application Support/Claude Multi Account/Profiles/\(pid.uuidString)/claude-code-sessions/acc/org"
        t.writeJSON("\(prof)/local_1.json", ["completedTurns": 1, "lastActivityAt": 1])
        t.writeJSON("\(prof)/\(ArchivedSessionsIndex.fileName)", ["v": 1, "archived": ["local_1"]])
        t.write("\(reg)/\(ArchivedSessionsIndex.fileName)", "{future format")
        t.writeJSON("\(reg)/local_0.json", ["completedTurns": 1, "lastActivityAt": 1])
        let plan = try SessionSyncPlanner.plan(a: SessionInventory.scan(ClaudeDataDir(t.paths.regularClaudeDir).sessionsDir), aAccount: "acc",
                                               b: SessionInventory.scan(ClaudeDataDir(t.paths.dataDir(for: pid)).sessionsDir), bAccount: "acc",
                                               oneWayFrom: .b, backupRoot: SessionSyncPlanner.backupRoot(paths: t.paths))
        #expect(plan.archiveUpdates.count == 1)
        let r = try SessionSyncExecutor(paths: t.paths).execute(plan)
        #expect(r.copied == ["local_1"])
        #expect(r.indexesSkipped.count == 1 && r.indexesUpdated.isEmpty)
        #expect(t.data("\(reg)/\(ArchivedSessionsIndex.fileName)") == Data("{future format".utf8))
        #expect(ArchivedSessionsIndex.mergeOutcome(Data(#"{"archived":"x"}"#.utf8), adding: ["a"]) == .unreadable)
    }

    // M3: writing through a symlinked ~/.claude/CLAUDE.md keeps the link and the file's permissions.
    @Test func generalRulesKeepSymlinkAndMode() throws {
        let t = TempDir()
        let real = t.write("dotfiles/CLAUDE.md", "# Mine\n")
        chmod(real.path, 0o600)
        let claudeDir = t.url.appending(path: ".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let link = claudeDir.appending(path: "CLAUDE.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/CLAUDE.md")
        let note = "---\nname: Use tabs\ndescription: d\n---\nAlways use tabs.\n"
        let n = try #require(MemoryStore.loadNote(t.write("p/memory/tabs.md", note), project: "proj"))
        let bk = t.url.appending(path: "bk")
        #expect(try MemoryOps.makeGeneralRules([n], claudeMD: link, backupDir: bk) == 1)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == "../dotfiles/CLAUDE.md")
        let text = try String(contentsOf: real, encoding: .utf8)
        #expect(text.hasPrefix("# Mine\n") && text.contains("Always use tabs."))
        let mode = (try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        // The backup is the real file's old content, not a copy of the link.
        let backup = bk.appending(path: "CLAUDE.md")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: backup.path)) == nil)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "# Mine\n")
    }

    // M5: a failed Dock read never writes.
    @Test func dockRefusesWriteWhenReadFails() throws {
        final class FailingStore: DockPreferencesStore, @unchecked Sendable {
            var writes = 0
            func persistentApps() -> [Any]? { nil }
            func setPersistentApps(_ apps: [Any]) throws { writes += 1 }
        }
        let store = FailingStore()
        let dock = DockEditor(store: store)
        #expect(throws: DockEditorError.readFailed) {
            try dock.add(appURL: URL(fileURLWithPath: "/tmp/x.app"), label: "x", bundleID: "b")
        }
        #expect(throws: DockEditorError.readFailed) { try dock.remove(bundleID: "b") }
        #expect(store.writes == 0)
    }

    // L1: removal is confined to the bin dirs and to files still carrying this profile's marker.
    @Test func terminalRemovalIsContained() throws {
        let t = TempDir()
        let bin = t.url.appending(path: "bin")
        let inst = TerminalCommandInstaller(paths: t.paths, binDirs: [bin])
        let p = Profile(name: "Work", color: .blue)
        let installed = try inst.install(p)
        // Same script content outside the bin dirs: refused.
        let outside = t.write("elsewhere/claude-work", try String(contentsOf: installed, encoding: .utf8))
        #expect(throws: SafePathError.self) { try inst.removeOwned(outside, profileID: p.id) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
        // A file in the bin dir without our marker: refused.
        let foreign = t.write("bin/claude-other", "#!/bin/sh\n")
        #expect(throws: TerminalCommandError.foreignFileExists(foreign.path)) { try inst.removeOwned(foreign, profileID: p.id) }
        try inst.removeOwned(installed, profileID: p.id)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
    }

    // L2: one validator for links everywhere (agent, launcher).
    @Test func linkValidation() throws {
        #expect(LinkRouting.parse("claude://claude.ai/new") != nil)
        #expect(LinkRouting.parse("claude://x y") == nil)
        #expect(LinkRouting.parse("claude://x\ny") == nil)
        #expect(LinkRouting.parse("claude://x%0Ay") != nil) // encoded is fine
        #expect(LinkRouting.parse("https://example.com") == nil)
        #expect(LinkRouting.parse("claude://" + String(repeating: "a", count: 9000)) == nil)
        let bad = try #require(URL(string: "https://example.com"))
        #expect(throws: ClaudeLaunchError.invalidURL) { try ClaudeLauncher.sendGetURL(bad, toPID: -1) }
    }

    // L3: the quit secret is a private 0600 file shared by manager and agent.
    @Test func quitTokenIsPrivateAndStable() throws {
        let t = TempDir()
        let id = UUID()
        let a = try QuitToken.load(paths: t.paths, profileID: id)
        let b = try QuitToken.load(paths: t.paths, profileID: id)
        #expect(a == b && a.count == 64)
        let u = QuitToken.url(paths: t.paths, profileID: id)
        let mode = (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(QuitToken.matches(a, expected: a))
        #expect(!QuitToken.matches(nil, expected: a))
        #expect(!QuitToken.matches(String(a.reversed()), expected: a))
        chmod(u.path, 0o644)
        #expect(throws: QuitTokenError.unsafeFile(u.path)) { try QuitToken.load(paths: t.paths, profileID: id) }
        QuitToken.remove(paths: t.paths, profileID: id)
        #expect(!FileManager.default.fileExists(atPath: u.path))
    }

    // L4: exported backups are owner-only.
    @Test func exportedBackupIsOwnerOnly() async throws {
        let t = TempDir()
        let p = Profile(name: "Work", color: .purple)
        t.write("Library/Application Support/Claude Multi Account/Profiles/\(p.id.uuidString)/config.json", "{}")
        let out = t.url.appending(path: "out/backup.zip")
        try await BackupArchiver(paths: t.paths).export(p, to: out)
        let mode = (try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    // F8: an instance whose arguments can't be read blocks every quit gate.
    @Test func unreadableArgvCountsAsRunning() {
        let s = ProcessScanner(paths: AppPaths(home: URL(fileURLWithPath: "/nonexistent-home")))
        let (kind, _) = s.classify(arguments: nil)
        #expect(kind.isUnidentified)
        let list = [ClaudeInstance(pid: 7, kind: kind, dataDir: URL(fileURLWithPath: "/dev/null"), isFrontmost: false)]
        #expect(list.mayBeRunning(.regular))
        #expect(list.mayBeRunning(.profile(UUID())))
        let known = [ClaudeInstance(pid: 8, kind: .foreign(dataDir: "/f"), dataDir: URL(fileURLWithPath: "/f"), isFrontmost: false)]
        #expect(!known.mayBeRunning(.regular))
    }

    // F9: apps left under an old name are found by profile id and removed with the profile.
    @Test func staleRenamedAppIsRemoved() async throws {
        let t = TempDir()
        let agent = t.url.appending(path: "agent/ProfileAgent")
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: agent)
        let b = BundleBuilder(paths: t.paths, agentBinary: agent, lsregister: nil)
        var p = Profile(name: "Old", color: .green)
        let oldApp = try await b.build(p)
        p.name = "New"
        let newApp = try await b.build(p) // simulates an interrupted rename: old app not removed
        #expect(b.installedApps(profileID: p.id).count == 2)
        try await b.removeStaleApps(for: p)
        #expect(!FileManager.default.fileExists(atPath: oldApp.path))
        #expect(FileManager.default.fileExists(atPath: newApp.path))
        try await b.remove(p)
        #expect(b.installedApps(profileID: p.id).isEmpty)
    }
}
