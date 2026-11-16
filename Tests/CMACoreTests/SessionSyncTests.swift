import Foundation
import Testing
@testable import CMACore

@Suite struct SessionSyncTests {
    let acc = "aaaaaaaa-0000-0000-0000-000000000001"
    let acc2 = "bbbbbbbb-0000-0000-0000-000000000002"
    let org = "00000000-0000-0000-0000-0000000000aa"
    let org2 = "00000000-0000-0000-0000-0000000000bb"

    func record(_ t: TempDir, side: String, account: String, org: String, id: String, turns: Int, activity: Double = 0,
                archived: Bool = false, extra: String = "") {
        let json = #"{"cliSessionId":"cli-\#(id)","createdAt":1,"lastActivityAt":\#(activity),"completedTurns":\#(turns),"lastTurnEdgeAt":0,"isArchived":\#(archived),"cwd":"/p","x":"\#(extra)"}"#
        t.write("\(side)/\(account)/\(org)/local_\(id).json", json)
    }

    @Test func scanIgnoresSiblings() {
        let t = TempDir()
        record(t, side: "A", account: acc, org: org, id: "1", turns: 1)
        t.write("A/\(acc)/\(org)/scheduled-tasks.json", "{}")
        t.write("A/\(acc)/\(org)/backlog/local_9.json", "{}")
        t.write("A/\(acc)/\(org)/waiting-input/x", "")
        t.write("A/\(acc)/\(org)/deleted_7", "")
        t.write("A/\(acc)/\(org)/archived-sessions.idx", #"{"v":1,"archived":["local_1"]}"#)
        let inv = SessionInventory.scan(t.url.appending(path: "A"))
        #expect(inv.records.map(\.sessionId) == ["local_1"])
        #expect(inv.records[0].completedTurns == 1)
        #expect(inv.records[0].cliSessionId == "cli-1")
        #expect(inv.isTombstoned("local_7", account: acc))
        #expect(inv.isArchived(inv.records[0]))
        #expect(inv.orgsByAccount[acc] == [org])
    }

    @Test func furtherAlongOrdering() {
        let u = URL(filePath: "/x")
        let a = SessionRecord(sessionId: "s", account: acc, org: org, url: u, lastActivityAt: 5, completedTurns: 3)
        let b = SessionRecord(sessionId: "s", account: acc, org: org, url: u, lastActivityAt: 99, completedTurns: 2)
        #expect(SessionRecord.compareProgress(a, b) == .orderedDescending)
        let c = SessionRecord(sessionId: "s", account: acc, org: org, url: u, lastActivityAt: 6, completedTurns: 3)
        #expect(SessionRecord.compareProgress(c, a) == .orderedDescending)
        let d = SessionRecord(sessionId: "s", account: acc, org: org, url: u, lastActivityAt: 6, completedTurns: 3, lastTurnEdgeAt: 1)
        #expect(SessionRecord.compareProgress(c, d) == .orderedAscending)
        let e = SessionRecord(sessionId: "s", account: acc, org: org, url: u, lastActivityAt: 6, completedTurns: 3, lastTurnEdgeAt: 1, modifiedAt: Date())
        #expect(SessionRecord.compareProgress(e, d) == .orderedDescending)
        #expect(SessionRecord.compareProgress(d, d) == .orderedSame)
    }

    @Test func twoWaySameAccount() throws {
        let t = TempDir()
        record(t, side: "A", account: acc, org: org, id: "onlyA", turns: 1, archived: true)
        record(t, side: "B", account: acc, org: org, id: "onlyB", turns: 1)
        record(t, side: "A", account: acc, org: org, id: "aWins", turns: 5)
        record(t, side: "B", account: acc, org: org, id: "aWins", turns: 2)
        record(t, side: "A", account: acc, org: org, id: "bWins", turns: 1, activity: 10)
        record(t, side: "B", account: acc, org: org, id: "bWins", turns: 1, activity: 20)
        record(t, side: "A", account: acc, org: org, id: "same", turns: 1)
        record(t, side: "B", account: acc, org: org, id: "same", turns: 1)
        record(t, side: "A", account: acc, org: org, id: "dead", turns: 9)
        t.write("B/\(acc)/\(org)/deleted_dead", "")
        record(t, side: "A", account: acc2, org: org, id: "otherAccount", turns: 1)
        let a = SessionInventory.scan(t.url.appending(path: "A")), b = SessionInventory.scan(t.url.appending(path: "B"))
        let backup = t.url.appending(path: "bk")
        let plan = try SessionSyncPlanner.plan(a: a, aAccount: acc.uppercased(), b: b, bAccount: acc, backupRoot: backup)
        #expect(plan.mode == .twoWay)
        let byID = Dictionary(uniqueKeysWithValues: plan.copies.map { ($0.sessionId, $0) })
        #expect(Set(byID.keys) == ["local_onlyA", "local_onlyB", "local_aWins", "local_bWins"])
        #expect(byID["local_onlyA"]?.from == .a)
        #expect(byID["local_onlyA"]?.replaces == false)
        #expect(byID["local_onlyA"]?.destination.path == t.url.appending(path: "B/\(acc)/\(org)/local_onlyA.json").path)
        #expect(byID["local_onlyB"]?.from == .b)
        #expect(byID["local_aWins"]?.replaces == true)
        #expect(byID["local_aWins"]?.backup?.path == backup.appending(path: "b/\(acc)/\(org)/local_aWins.json").path)
        #expect(byID["local_bWins"]?.from == .b)
        #expect(byID["local_bWins"]?.backup?.path.hasPrefix(backup.appending(path: "a").path) == true)
        #expect(plan.skippedTombstoned == ["local_dead"])
        #expect(plan.skippedIdentical == ["local_same"])
        #expect(plan.skippedNotNewer.isEmpty)
        #expect(plan.archiveUpdates == [ArchiveIndexUpdate(indexURL: t.url.appending(path: "B/\(acc)/\(org)/archived-sessions.idx"), addIDs: ["local_onlyA"],
                                                         backup: backup.appending(path: "b/\(acc)/\(org)/archived-sessions.idx"))])
    }

    @Test func crossAccountIsOneWayAndRehomes() throws {
        let t = TempDir()
        record(t, side: "A", account: acc, org: org, id: "s1", turns: 2)
        record(t, side: "A", account: acc, org: org, id: "s2", turns: 1)
        record(t, side: "B", account: acc2, org: org2, id: "s2", turns: 4)
        record(t, side: "B", account: acc2, org: org2, id: "bOnly", turns: 4)
        let a = SessionInventory.scan(t.url.appending(path: "A")), b = SessionInventory.scan(t.url.appending(path: "B"))
        let bk = t.url.appending(path: "bk")
        #expect(throws: SessionSyncError.directionRequired) {
            try SessionSyncPlanner.plan(a: a, aAccount: acc, b: b, bAccount: acc2, backupRoot: bk)
        }
        #expect(throws: SessionSyncError.unknownAccount(.b)) {
            try SessionSyncPlanner.plan(a: a, aAccount: acc, b: b, bAccount: nil, backupRoot: bk)
        }
        let plan = try SessionSyncPlanner.plan(a: a, aAccount: acc, b: b, bAccount: acc2, oneWayFrom: .a, backupRoot: bk)
        #expect(plan.mode == .oneWay(from: .a))
        #expect(plan.copies.map(\.sessionId) == ["local_s1"])
        #expect(plan.copies[0].destination.path == t.url.appending(path: "B/\(acc2)/\(org2)/local_s1.json").path)
        #expect(plan.skippedNotNewer == ["local_s2"])
        #expect(!plan.copies.contains { $0.from == .b })
    }

    @Test func crossAccountDestinationOrgResolution() throws {
        let t = TempDir()
        record(t, side: "A", account: acc, org: org, id: "s1", turns: 2)
        let a = SessionInventory.scan(t.url.appending(path: "A"))
        let empty = SessionInventory.scan(t.url.appending(path: "B"))
        #expect(throws: SessionSyncError.noDestinationOrg) {
            try SessionSyncPlanner.plan(a: a, aAccount: acc, b: empty, bAccount: acc2, oneWayFrom: .a, backupRoot: t.url)
        }
        let p = try SessionSyncPlanner.plan(a: a, aAccount: acc, b: empty, bAccount: acc2, oneWayFrom: .a, destinationOrg: org2, backupRoot: t.url)
        #expect(p.copies[0].destination.path.hasSuffix("B/\(acc2)/\(org2)/local_s1.json"))
        t.write("B/\(acc2)/o1/x", ""); t.write("B/\(acc2)/o2/x", "")
        let two = SessionInventory.scan(t.url.appending(path: "B"))
        #expect(throws: SessionSyncError.ambiguousDestinationOrg(["o1", "o2"])) {
            try SessionSyncPlanner.plan(a: a, aAccount: acc, b: two, bAccount: acc2, oneWayFrom: .a, backupRoot: t.url)
        }
    }

    @Test func archiveIndexMerge() throws {
        let merged = try #require(ArchivedSessionsIndex.merge(Data(#"{"v":1,"archived":["x"],"k":true}"#.utf8), adding: ["y", "x", "y"]))
        let obj = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        #expect(obj["archived"] as? [String] == ["x", "y"])
        #expect(obj["k"] as? Bool == true)
        #expect(ArchivedSessionsIndex.merge(merged, adding: ["x"]) == nil)
        let fresh = try #require(ArchivedSessionsIndex.merge(nil, adding: ["a"]))
        #expect(ArchivedSessionsIndex.ids(fresh) == ["a"])
        #expect(SessionSyncPlanner.backupRoot(paths: AppPaths(home: URL(filePath: "/h")), date: Date(timeIntervalSince1970: 0)).path
                == "/h/Library/Application Support/Claude Multi Account/Backups/session-sync/19700101-000000")
    }
}
