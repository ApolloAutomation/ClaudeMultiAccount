import Foundation
import Testing
@testable import CMACore
@testable import CMASystem

@Suite struct SessionSyncExecutorTests {
    func record(turns: Int, activity: Double, extra: String = "") -> [String: Any] {
        ["cliSessionId": "cli", "completedTurns": turns, "lastActivityAt": activity, "lastTurnEdgeAt": 0, "cwd": "/x", "note": extra]
    }

    @Test func backsUpReplacedAndLeavesSourceIdentical() throws {
        let t = TempDir()
        let paths = t.paths
        let pid = UUID()
        let regSessions = "Library/Application Support/Claude/claude-code-sessions/acc/org"
        let profSessions = "Library/Application Support/Claude Multi Account/Profiles/\(pid.uuidString)/claude-code-sessions/acc/org"
        t.writeJSON("\(regSessions)/local_1.json", record(turns: 5, activity: 500))
        t.writeJSON("\(regSessions)/local_3.json", record(turns: 1, activity: 100))
        t.writeJSON("\(regSessions)/\(ArchivedSessionsIndex.fileName)", ["v": 1, "archived": ["local_3"]])
        t.writeJSON("\(profSessions)/local_1.json", record(turns: 2, activity: 200, extra: "old"))
        t.writeJSON("\(profSessions)/local_2.json", record(turns: 3, activity: 300))
        t.write("\(profSessions)/deleted_4", "")
        t.writeJSON("\(regSessions)/local_4.json", record(turns: 9, activity: 900))

        let regDir = ClaudeDataDir(paths.regularClaudeDir)
        let profDir = ClaudeDataDir(paths.dataDir(for: pid))
        let before = treeSnapshot(regDir.sessionsDir)
        let oldProf1 = t.data("\(profSessions)/local_1.json")
        let backupRoot = SessionSyncPlanner.backupRoot(paths: paths)
        let plan = try SessionSyncPlanner.plan(a: SessionInventory.scan(regDir.sessionsDir), aAccount: "acc",
                                               b: SessionInventory.scan(profDir.sessionsDir), bAccount: "acc", backupRoot: backupRoot)
        let r = try SessionSyncExecutor(paths: paths).execute(plan)

        #expect(Set(r.copied) == ["local_1", "local_2", "local_3"])
        // Profile now has the further-along record; old one backed up byte-for-byte.
        #expect(t.data("\(profSessions)/local_1.json") == t.data("\(regSessions)/local_1.json"))
        let backup = try #require(r.backups.first { $0.lastPathComponent == "local_1.json" })
        #expect(try Data(contentsOf: backup) == oldProf1)
        #expect(backup.path.hasPrefix(paths.backupsDir.path))
        // Tombstoned id never copied.
        #expect(!t.exists("\(profSessions)/local_4.json"))
        // Archive index updated for the copied archived id.
        #expect(ArchivedSessionsIndex.ids(t.data("\(profSessions)/\(ArchivedSessionsIndex.fileName)")) == ["local_3"])
        // Regular side: only local_2 added; every pre-existing source file byte-identical.
        let after = treeSnapshot(regDir.sessionsDir)
        for (k, v) in before { #expect(after[k] == v, "\(k) changed") }
        #expect(Set(after.keys).subtracting(before.keys) == ["acc/org/local_2.json"])

        // Second run: nothing left to do.
        let again = try SessionSyncPlanner.plan(a: SessionInventory.scan(regDir.sessionsDir), aAccount: "acc",
                                                b: SessionInventory.scan(profDir.sessionsDir), bAccount: "acc", backupRoot: backupRoot)
        #expect(again.copies.isEmpty)
    }

    @Test func recheckSkipsDestinationThatAdvanced() throws {
        let t = TempDir()
        let pid = UUID()
        let reg = "Library/Application Support/Claude/claude-code-sessions/acc/org"
        let prof = "Library/Application Support/Claude Multi Account/Profiles/\(pid.uuidString)/claude-code-sessions/acc/org"
        t.writeJSON("\(reg)/local_1.json", record(turns: 5, activity: 500))
        t.writeJSON("\(prof)/local_1.json", record(turns: 2, activity: 200))
        let plan = try SessionSyncPlanner.plan(a: SessionInventory.scan(ClaudeDataDir(t.paths.regularClaudeDir).sessionsDir), aAccount: "acc",
                                               b: SessionInventory.scan(ClaudeDataDir(t.paths.dataDir(for: pid)).sessionsDir), bAccount: "acc",
                                               backupRoot: SessionSyncPlanner.backupRoot(paths: t.paths))
        // Destination moves on between plan and execute.
        t.writeJSON("\(prof)/local_1.json", record(turns: 8, activity: 800))
        let before = t.data("\(prof)/local_1.json")
        let r = try SessionSyncExecutor(paths: t.paths).execute(plan)
        #expect(r.skippedChanged == ["local_1"])
        #expect(t.data("\(prof)/local_1.json") == before)
    }
}

@Suite struct SettingsImportExecutorTests {
    @Test func importsMissingOnlyWithBackup() throws {
        let t = TempDir()
        let pid = UUID()
        let src = ClaudeDataDir(t.paths.regularClaudeDir)
        let dst = ClaudeDataDir(t.paths.dataDir(for: pid))
        t.writeJSON("Library/Application Support/Claude/claude_desktop_config.json", ["mcpServers": ["a": ["command": "x"], "b": ["command": "y"]]])
        t.writeJSON("Library/Application Support/Claude/config.json", ["darkMode": true, "oauth:tokenCache": "secret"])
        let destRel = "Library/Application Support/Claude Multi Account/Profiles/\(pid.uuidString)"
        t.writeJSON("\(destRel)/claude_desktop_config.json", ["mcpServers": ["a": ["command": "keep"]]])
        t.writeJSON("\(destRel)/config.json", ["lastKnownAccountUuid": "acc"])
        let oldCfg = t.data("\(destRel)/claude_desktop_config.json")
        let plan = try SettingsImportPlanner.plan(from: src, to: dst)
        let r = try SettingsImportExecutor(paths: t.paths).execute(plan, into: dst)
        let merged = try #require(try AtomicFile.readJSONObject(at: dst.desktopConfigJSON))
        let servers = try #require(merged["mcpServers"] as? [String: Any])
        #expect((servers["a"] as? [String: Any])?["command"] as? String == "keep")
        #expect(servers["b"] != nil)
        #expect(r.backups.contains { (try? Data(contentsOf: $0)) == oldCfg })
        let cfg = try #require(try AtomicFile.readJSONObject(at: dst.configJSON))
        #expect(cfg["darkMode"] as? Bool == true)
        #expect(cfg["lastKnownAccountUuid"] as? String == "acc")
        #expect(cfg["oauth:tokenCache"] == nil)
    }
}

@Suite struct RegularClaudeMoverTests {
    func seed(_ t: TempDir) {
        t.write("Library/Application Support/Claude/config.json", #"{"lastKnownAccountUuid":"acc"}"#)
        t.write("Library/Application Support/Claude/Local Storage/leveldb/1.log", "x")
    }

    @Test func movesWithSingleRename() throws {
        let t = TempDir(); seed(t)
        let before = treeSnapshot(t.paths.regularClaudeDir)
        let m = RegularClaudeMover(paths: t.paths, isRegularClaudeRunning: { false })
        let id = UUID()
        let e = try m.move(to: id)
        #expect(e.step == RegularClaudeMover.stepMoved)
        #expect(!FileManager.default.fileExists(atPath: t.paths.regularClaudeDir.path))
        #expect(treeSnapshot(t.paths.dataDir(for: id)) == before)
        #expect(try m.recover() == [.needsProfile(entryID: e.id, profileID: id, dataDir: t.paths.dataDir(for: id))])
        try m.complete(e)
        #expect(OperationJournal(paths: t.paths).pending().isEmpty)
    }

    @Test func refusesWhileRunning() throws {
        let t = TempDir(); seed(t)
        let m = RegularClaudeMover(paths: t.paths, isRegularClaudeRunning: { true })
        #expect(throws: RegularClaudeMoveError.claudeRunning) { try m.move(to: UUID()) }
        #expect(FileManager.default.fileExists(atPath: t.paths.regularClaudeDir.path))
    }

    @Test func recoversInterruptedRename() throws {
        let t = TempDir(); seed(t)
        let id = UUID()
        let journal = OperationJournal(paths: t.paths)
        let m = RegularClaudeMover(paths: t.paths, isRegularClaudeRunning: { false })
        // Crash after rename, before the journal advanced.
        let e1 = try journal.begin(.moveRegularClaude, payload: ["profileID": id.uuidString])
        try FileManager.default.createDirectory(at: t.paths.profilesDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: t.paths.regularClaudeDir, to: t.paths.dataDir(for: id))
        #expect(try m.recover() == [.needsProfile(entryID: e1.id, profileID: id, dataDir: t.paths.dataDir(for: id))])
        #expect(journal.pending().first?.step == RegularClaudeMover.stepMoved)
        try journal.complete(e1.id)

        // Crash before rename: rolled back, journal cleared.
        seed(t)
        let e2 = try journal.begin(.moveRegularClaude, payload: ["profileID": UUID().uuidString])
        #expect(try m.recover() == [.rolledBack(entryID: e2.id)])
        #expect(journal.pending().isEmpty)
        #expect(FileManager.default.fileExists(atPath: t.paths.regularClaudeDir.path))
    }

    @Test func crossVolumeCopiesVerifiesAndTrashes() throws {
        let t = TempDir(); seed(t)
        let before = treeSnapshot(t.paths.regularClaudeDir)
        let trashed = t.url.appending(path: "Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        let regular = t.paths.regularClaudeDir.path
        let m = RegularClaudeMover(paths: t.paths, isRegularClaudeRunning: { false },
                                   trash: { try FileManager.default.moveItem(at: $0, to: trashed.appending(path: $0.lastPathComponent)) },
                                   renameFn: { src, dst in src == regular ? EXDEV : (Darwin.rename(src, dst) == 0 ? 0 : errno) })
        let id = UUID()
        let e = try m.move(to: id)
        #expect(e.step == RegularClaudeMover.stepMoved)
        #expect(treeSnapshot(t.paths.dataDir(for: id)) == before)
        #expect(treeSnapshot(trashed.appending(path: "Claude")) == before)
        #expect(!FileManager.default.fileExists(atPath: regular))
    }

    @Test func recoversCopiedStep() throws {
        let t = TempDir(); seed(t)
        let id = UUID()
        let journal = OperationJournal(paths: t.paths)
        try FileManager.default.createDirectory(at: t.paths.profilesDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: t.paths.regularClaudeDir, to: t.paths.dataDir(for: id))
        var e = try journal.begin(.moveRegularClaude, payload: ["profileID": id.uuidString])
        e = try journal.advance(e, to: RegularClaudeMover.stepCopied)
        let trashedBox = TempDir()
        let m = RegularClaudeMover(paths: t.paths, isRegularClaudeRunning: { false },
                                   trash: { try FileManager.default.moveItem(at: $0, to: trashedBox.url.appending(path: "c")) })
        #expect(try m.recover() == [.needsProfile(entryID: e.id, profileID: id, dataDir: t.paths.dataDir(for: id))])
        #expect(!FileManager.default.fileExists(atPath: t.paths.regularClaudeDir.path))
    }
}
