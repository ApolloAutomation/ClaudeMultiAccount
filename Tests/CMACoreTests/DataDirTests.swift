import Foundation
import Testing
@testable import CMACore

@Suite struct DataDirTests {
    @Test func accountUUIDOnly() {
        let acc = "11111111-2222-3333-4444-555555555555"
        let cfg = #"{"oauth:tokenCache":"SECRET","oauth:tokenCacheV2":{"a":1},"lastKnownAccountUuid":"\#(acc)","darkMode":true}"#
        #expect(ClaudeDataDir.accountUUID(fromConfig: Data(cfg.utf8)) == acc)
        #expect(ClaudeDataDir.accountUUID(fromConfig: Data(#"{"lastKnownAccountUuid":"not-a-uuid"}"#.utf8)) == nil)
        #expect(ClaudeDataDir.accountUUID(fromConfig: Data(#"{"lastKnownAccountUuid":5}"#.utf8)) == nil)
        #expect(ClaudeDataDir.accountUUID(fromConfig: Data("{}".utf8)) == nil)
        #expect(ClaudeDataDir.accountUUID(fromConfig: Data("[".utf8)) == nil)
        let t = TempDir()
        t.write("d/config.json", cfg)
        let dd = ClaudeDataDir(t.url.appending(path: "d"))
        #expect(dd.accountUUID() == acc)
        #expect(dd.exists)
        #expect(ClaudeDataDir(t.url.appending(path: "nope")).accountUUID() == nil)
    }
}

@Suite struct PlanUsageTests {
    let json = #"""
    {"version":2,"samples":[
      {"t":1000000,"org":"o1","u":{"fh":10,"sd":20}},
      {"t":3000000,"org":"o1","u":{"sd":33.6}},
      {"t":2000000,"org":"o2","u":{"fh":96}},
      {"t":"bad","org":"o2"},
      {"t":4000000}
    ]}
    """#

    @Test func parseAndLatest() throws {
        let s = PlanUsage.parse(Data(json.utf8))
        #expect(s.count == 3)
        let l = try #require(PlanUsage.latest(s, org: "o1"))
        #expect(l.fiveHour == nil)
        #expect(l.sevenDay == 33.6)
        #expect(PlanUsage.latest(s)?.org == "o1")
        let per = PlanUsage.latestPerOrg(s)
        #expect(per["o1"]?.t == Date(timeIntervalSince1970: 3000))
        #expect(per["o2"]?.fiveHour == 96)
        #expect(PlanUsage.parse(Data("garbage".utf8)).isEmpty)
    }

    @Test func staleRuleAndLevels() throws {
        let s = PlanUsage.parse(Data(json.utf8))
        let fresh = try #require(PlanUsage.snapshot(s, org: "o2", now: Date(timeIntervalSince1970: 2000 + 3600)))
        #expect(fresh.fiveHour == 96)
        let stale = try #require(PlanUsage.snapshot(s, org: "o2", now: Date(timeIntervalSince1970: 2000 + 5 * 3600 + 1)))
        #expect(stale.fiveHour == nil)
        #expect(PlanUsage.snapshot(s, org: "zz") == nil)
        #expect(PlanUsage.display(nil) == "—")
        #expect(PlanUsage.display(33.6) == "34%")
        #expect(PlanUsage.level(79.9) == .normal)
        #expect(PlanUsage.level(80) == .warning)
        #expect(PlanUsage.level(95) == .critical)
        #expect(PlanUsage.level(nil) == .normal)
    }
}

@Suite struct CacheInventoryTests {
    @Test func cacheAndExcludes() {
        let t = TempDir()
        t.write("d/Cache/a", String(repeating: "x", count: 5000))
        t.write("d/GPUCache/b", "y")
        t.write("d/Local Storage/c", "z")
        let dirs = CacheInventory.cacheDirs(in: t.url.appending(path: "d")).map(\.lastPathComponent)
        #expect(Set(dirs) == ["Cache", "GPUCache"])
        #expect(CacheInventory.cacheSize(in: t.url.appending(path: "d")) >= 5000)
        #expect(CacheInventory.isBackupExcluded("SingletonLock"))
        #expect(CacheInventory.isBackupExcluded("claude-code-vm"))
        #expect(CacheInventory.isBackupExcluded("Code Cache"))
        #expect(!CacheInventory.isBackupExcluded("claude-code-sessions"))
        #expect(!CacheInventory.isBackupExcluded("config.json"))
    }
}

@Suite struct ProcArgsTests {
    static func blob(exec: String, args: [String], env: [String], pad: Int = 3) -> [UInt8] {
        var b = withUnsafeBytes(of: Int32(args.count).littleEndian) { Array($0) }
        b += Array(exec.utf8) + [0] + Array(repeating: 0, count: pad)
        for a in args { b += Array(a.utf8) + [0] }
        for e in env { b += Array(e.utf8) + [0] }
        b += [0, 0]
        return b
    }

    @Test func parsesWithSpaces() throws {
        let dir = "/Users/x/Library/Application Support/Claude Multi Account/Profiles/AAA"
        let b = Self.blob(exec: "/Applications/Claude.app/Contents/MacOS/Claude",
                          args: ["/Applications/Claude.app/Contents/MacOS/Claude", "--user-data-dir=\(dir)", "--foo"],
                          env: ["HOME=/Users/x", "CLAUDE_CONFIG_DIR=/a b"])
        let p = try #require(ProcArgs.parse(b))
        #expect(p.executablePath == "/Applications/Claude.app/Contents/MacOS/Claude")
        #expect(p.arguments.count == 3)
        #expect(p.environment == ["HOME=/Users/x", "CLAUDE_CONFIG_DIR=/a b"])
        #expect(p.userDataDir == dir)
    }

    @Test func separateArgForm() {
        #expect(ProcArgs.userDataDir(from: ["Claude", "--user-data-dir", "/a b/c"]) == "/a b/c")
        #expect(ProcArgs.userDataDir(from: ["Claude", "--user-data-dir"]) == nil)
        #expect(ProcArgs.userDataDir(from: ["Claude", "--user-data-dir="]) == nil)
        #expect(ProcArgs.userDataDir(from: ["Claude", "--user-data-dir", "--other"]) == nil)
        #expect(ProcArgs.userDataDir(from: ["Claude"]) == nil)
        #expect(ProcArgs.userDataDir(from: ["--user-data-dir=/argv0"]) == nil)
        #expect(ProcArgs.userDataDir(from: ["C", "--user-data-dirx=/a"]) == nil)
    }

    @Test func malformed() {
        #expect(ProcArgs.parse([UInt8]()) == nil)
        #expect(ProcArgs.parse([1, 0, 0, 0]) == nil)
        var b = withUnsafeBytes(of: Int32(5).littleEndian) { Array($0) }
        b += Array("/x".utf8) + [0, 0] + Array("a".utf8) + [0]
        #expect(ProcArgs.parse(b) == nil)
        #expect(ProcArgs.parse([255, 255, 255, 255]) == nil)
    }

    @Test func normalizeCompare() throws {
        let t = TempDir()
        let real = t.url.appending(path: "Real Dir", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: t.url.appending(path: "link"), withDestinationURL: real)
        #expect(ProcArgs.sameDir(real.path, t.url.appending(path: "link").path + "/"))
        #expect(ProcArgs.sameDir(real.path.uppercased(), real.path + "/./"))
        #expect(!ProcArgs.sameDir(real.path, t.url.path))
    }

    @Test func fetchOwnProcess() throws {
        let p = try #require(ProcArgs.fetch(pid: getpid()))
        #expect(!p.arguments.isEmpty)
        #expect(!p.executablePath.isEmpty)
    }
}

@Suite struct LinkRoutingTests {
    let url = URL(string: "claude://claude.ai/new?q=hi")!
    func inst(_ pid: Int32, _ kind: InstanceKind, front: Bool = false, launched: Date? = nil) -> ClaudeInstance {
        ClaudeInstance(pid: pid, kind: kind, dataDir: URL(filePath: "/x"), isFrontmost: front, launchDate: launched)
    }

    @Test func decisions() {
        #expect(LinkRouting.decide(url: URL(string: "https://x")!, instances: []) == .reject)
        #expect(LinkRouting.decide(url: url, instances: []) == .openRegular)
        #expect(LinkRouting.decide(url: url, instances: [inst(9, .foreign(dataDir: "/f"))]) == .openRegular)
        #expect(LinkRouting.decide(url: url, instances: [inst(5, .regular), inst(9, .foreign(dataDir: "/f"))]) == .forward(pid: 5))
        let p1 = UUID(), p2 = UUID()
        let many = [inst(1, .regular, launched: Date(timeIntervalSince1970: 50)), inst(2, .profile(p1)), inst(3, .profile(p2))]
        let d = LinkRouting.decide(url: url, instances: many, lastActiveAt: [p1: Date(timeIntervalSince1970: 100), p2: Date(timeIntervalSince1970: 10)])
        #expect(d == .pick(candidates: many, preselected: 2))
        let front = [inst(1, .regular), inst(2, .profile(p1), front: true)]
        #expect(LinkRouting.decide(url: url, instances: front) == .pick(candidates: front, preselected: 2))
        #expect(LinkRouting.isValid(URL(string: "CLAUDE://x")!))
    }
}

@Suite struct DockPlistTests {
    @Test func addRemove() {
        let app = URL(filePath: "/Users/x/Applications/Claude Multi Account/Claude (Work).app", directoryHint: .isDirectory)
        var apps: [Any] = [DockPlist.tile(appURL: URL(filePath: "/Applications/Safari.app"), label: "Safari", bundleID: "com.apple.Safari")]
        apps = DockPlist.adding(apps, appURL: app, label: "Claude (Work)", bundleID: "b.1")
        #expect(apps.count == 2)
        #expect(DockPlist.contains(apps, bundleID: "B.1"))
        let td = (apps[1] as? [String: Any])?["tile-data"] as? [String: Any]
        #expect(td?["file-type"] as? Int == 41)
        #expect(td?["file-label"] as? String == "Claude (Work)")
        let fd = td?["file-data"] as? [String: Any]
        #expect(fd?["_CFURLStringType"] as? Int == 15)
        #expect((fd?["_CFURLString"] as? String)?.hasPrefix("file:///Users/x/Applications/Claude%20Multi%20Account/") == true)
        let again = DockPlist.adding(apps, appURL: URL(filePath: "/new.app"), label: "New", bundleID: "b.1")
        #expect(again.count == 2)
        #expect(DockPlist.urlString(of: again[1]) == URL(filePath: "/new.app").absoluteString)
        let removed = DockPlist.removing(again, bundleID: "b.1")
        #expect(removed.count == 1)
        #expect(DockPlist.bundleID(of: removed[0]) == "com.apple.Safari")
        #expect(PropertyListSerialization.propertyList(again, isValidFor: .binary))
    }
}
