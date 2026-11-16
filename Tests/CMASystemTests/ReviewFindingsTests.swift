import Foundation
import Testing
@testable import CMACore
@testable import CMASystem

/// Adversarial edge cases from review. Each test asserts the *correct* behavior, so a failure proves a bug.
@Suite struct ReviewFindingsTests {
    func record(turns: Int, activity: Double) -> [String: Any] {
        ["cliSessionId": "cli", "completedTurns": turns, "lastActivityAt": activity, "lastTurnEdgeAt": 0, "cwd": "/x"]
    }

    // F1: a case-only rename ("work" -> "Work") deletes the freshly built app on case-insensitive APFS.
    @Test func caseOnlyRenameKeepsApp() async throws {
        let t = TempDir()
        let agent = t.url.appending(path: "agent/ProfileAgent")
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: agent)
        let b = BundleBuilder(paths: t.paths, agentBinary: agent, lsregister: nil)
        var p = Profile(name: "work", color: .green)
        let old = try await b.build(p)
        p.name = "Work"
        #expect(NameValidator.validate(p.name, existing: [Profile(id: p.id, name: "work", color: .green)], excluding: p.id) == nil)
        let renamed = try await b.build(p, previousAppURL: old)
        #expect(FileManager.default.fileExists(atPath: renamed.path), "profile app was deleted by the rename")
    }

    // F2: after planning, the destination deletes the chat (tombstone). Executor resurrects it.
    @Test func executorHonorsTombstoneAddedAfterPreview() throws {
        let t = TempDir()
        let pid = UUID()
        let reg = "Library/Application Support/Claude/claude-code-sessions/acc/org"
        let prof = "Library/Application Support/Claude Multi Account/Profiles/\(pid.uuidString)/claude-code-sessions/acc/org"
        t.writeJSON("\(reg)/local_1.json", record(turns: 5, activity: 500))
        t.writeJSON("\(prof)/local_1.json", record(turns: 2, activity: 200))
        let plan = try SessionSyncPlanner.plan(a: SessionInventory.scan(ClaudeDataDir(t.paths.regularClaudeDir).sessionsDir), aAccount: "acc",
                                               b: SessionInventory.scan(ClaudeDataDir(t.paths.dataDir(for: pid)).sessionsDir), bAccount: "acc",
                                               backupRoot: SessionSyncPlanner.backupRoot(paths: t.paths))
        #expect(plan.copies.count == 1)
        // User deletes the chat in the profile between preview and Sync.
        try FileManager.default.removeItem(at: t.url.appending(path: "\(prof)/local_1.json"))
        t.write("\(prof)/deleted_1", "")
        _ = try SessionSyncExecutor(paths: t.paths).execute(plan)
        #expect(!t.exists("\(prof)/local_1.json"), "deleted chat was resurrected")
    }

    // F3: archive index replaced without a backup when no copy replaced a file.
    @Test func archiveIndexBackedUpBeforeReplace() throws {
        let t = TempDir()
        let pid = UUID()
        let reg = "Library/Application Support/Claude/claude-code-sessions/acc/org"
        let prof = "Library/Application Support/Claude Multi Account/Profiles/\(pid.uuidString)/claude-code-sessions/acc/org"
        t.writeJSON("\(reg)/local_3.json", record(turns: 1, activity: 100))
        t.writeJSON("\(reg)/\(ArchivedSessionsIndex.fileName)", ["v": 1, "archived": ["local_3"]])
        t.writeJSON("\(prof)/\(ArchivedSessionsIndex.fileName)", ["v": 1, "archived": ["local_9", ["id": "x"]]])
        let plan = try SessionSyncPlanner.plan(a: SessionInventory.scan(ClaudeDataDir(t.paths.regularClaudeDir).sessionsDir), aAccount: "acc",
                                               b: SessionInventory.scan(ClaudeDataDir(t.paths.dataDir(for: pid)).sessionsDir), bAccount: "acc",
                                               oneWayFrom: .a, backupRoot: SessionSyncPlanner.backupRoot(paths: t.paths))
        let r = try SessionSyncExecutor(paths: t.paths).execute(plan)
        #expect(r.indexesUpdated.count == 1)
        #expect(r.backups.contains { $0.lastPathComponent.hasSuffix(ArchivedSessionsIndex.fileName) }, "index replaced with no backup")
        // Non-string entries survive the merge.
        let obj = try JSONSerialization.jsonObject(with: try #require(t.data("\(prof)/\(ArchivedSessionsIndex.fileName)"))) as? [String: Any]
        #expect((obj?["archived"] as? [Any])?.count == 3, "non-string archived entries were dropped")
    }

    // F4: one bad destination file aborts mid-run; already-copied archived chats arrive un-archived.
    @Test func abortMidRunStillAppliesArchiveForCopied() throws {
        let t = TempDir()
        let pid = UUID()
        let reg = "Library/Application Support/Claude/claude-code-sessions/acc/org"
        let prof = "Library/Application Support/Claude Multi Account/Profiles/\(pid.uuidString)/claude-code-sessions/acc/org"
        t.writeJSON("\(reg)/local_3.json", record(turns: 1, activity: 100))
        t.writeJSON("\(reg)/local_9.json", record(turns: 4, activity: 400))
        t.writeJSON("\(reg)/\(ArchivedSessionsIndex.fileName)", ["v": 1, "archived": ["local_3"]])
        t.write("\(prof)/local_9.json", "{not json") // damaged on the destination
        t.writeJSON("\(prof)/local_0.json", record(turns: 1, activity: 1)) // keeps the org dir
        let plan = try SessionSyncPlanner.plan(a: SessionInventory.scan(ClaudeDataDir(t.paths.regularClaudeDir).sessionsDir), aAccount: "acc",
                                               b: SessionInventory.scan(ClaudeDataDir(t.paths.dataDir(for: pid)).sessionsDir), bAccount: "acc",
                                               oneWayFrom: .a, backupRoot: SessionSyncPlanner.backupRoot(paths: t.paths))
        _ = try? SessionSyncExecutor(paths: t.paths).execute(plan)
        if t.exists("\(prof)/local_3.json") {
            #expect(ArchivedSessionsIndex.ids(t.data("\(prof)/\(ArchivedSessionsIndex.fileName)")).contains("local_3"),
                    "archived chat copied but shows as un-archived after abort")
        }
    }

    // F5: interrupted move at "begin" where regular Claude has since recreated its dir: the moved sign-in is orphaned.
    @Test func beginStepWithBothDirsDoesNotOrphanMovedData() throws {
        let t = TempDir()
        t.write("Library/Application Support/Claude/config.json", #"{"lastKnownAccountUuid":"acc"}"#)
        let id = UUID()
        let journal = OperationJournal(paths: t.paths)
        _ = try journal.begin(.moveRegularClaude, payload: ["profileID": id.uuidString])
        try FileManager.default.createDirectory(at: t.paths.profilesDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: t.paths.regularClaudeDir, to: t.paths.dataDir(for: id))
        t.write("Library/Application Support/Claude/fresh.json", "{}") // regular Claude launched before the manager
        let m = RegularClaudeMover(paths: t.paths, isRegularClaudeRunning: { false })
        let out = try m.recover()
        let recovered = out.contains { if case .needsProfile = $0 { return true }; return false }
        #expect(recovered || !journal.pending().isEmpty, "moved data left in Profiles/<UUID> with no profile and no journal")
    }

    // F6: recovery at step "copied" trashes regular Claude's dir without checking it is quit.
    @Test func copiedStepRecoveryRefusesWhileRunning() throws {
        let t = TempDir()
        t.write("Library/Application Support/Claude/config.json", "{}")
        let id = UUID()
        try FileManager.default.createDirectory(at: t.paths.profilesDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: t.paths.regularClaudeDir, to: t.paths.dataDir(for: id))
        let journal = OperationJournal(paths: t.paths)
        var e = try journal.begin(.moveRegularClaude, payload: ["profileID": id.uuidString])
        e = try journal.advance(e, to: RegularClaudeMover.stepCopied)
        let trashed = TempDir()
        let m = RegularClaudeMover(paths: t.paths, isRegularClaudeRunning: { true },
                                   trash: { try FileManager.default.moveItem(at: $0, to: trashed.url.appending(path: "c")) })
        _ = try? m.recover()
        #expect(FileManager.default.fileExists(atPath: t.paths.regularClaudeDir.path), "trashed a running Claude's data dir")
    }
}

// F7: a pending debounced re-check is cancelled by every safety tick; when debounce+backoff > safetyInterval
// (production: backoff >= 60 s after ~7 re-claims in 10 min) the re-claim never runs again.
@Suite @MainActor struct ReviewLinkTests {
    @Test func safetyTickDoesNotStarveReclaim() async throws {
        let reg = FakeRegistry()
        let ours = URL(fileURLWithPath: "/tmp/ours.app"), claude = URL(fileURLWithPath: "/tmp/Claude.app")
        let l = LinkHandlerRegistration(registry: reg, ourAppURL: ours, claudeAppURL: { claude },
                                        debounce: .milliseconds(300), safetyInterval: .milliseconds(100))
        try await l.enable()
        reg.lock.withLock { reg.current = claude }
        try await Task.sleep(for: .seconds(2))
        let count = l.reclaimCount
        l.disableWatchingForTest()
        #expect(count > 0, "re-claim starved by the safety tick")
    }
}

extension LinkHandlerRegistration {
    func disableWatchingForTest() { Task { try? await self.disable() } }
}
