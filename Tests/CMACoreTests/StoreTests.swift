import Foundation
import Testing
@testable import CMACore

@Suite struct AtomicAndSafePathTests {
    @Test func atomicWriteReplacesAndLeavesNoTemp() throws {
        let t = TempDir()
        let f = t.url.appending(path: "a/b/x.json")
        try AtomicFile.write("one", to: f)
        try AtomicFile.write("two", to: f, permissions: 0o600)
        #expect(t.read("a/b/x.json") == "two")
        let names = try FileManager.default.contentsOfDirectory(atPath: t.url.appending(path: "a/b").path)
        #expect(names == ["x.json"])
    }

    @Test func jsonRoundTripPreservesUnknownKeys() throws {
        let t = TempDir()
        let f = t.url.appending(path: "c.json")
        try AtomicFile.writeJSONObject(["keep": ["n": 1], "x": "y"], to: f)
        var obj = try #require(try AtomicFile.readJSONObject(at: f))
        obj["x"] = "z"
        try AtomicFile.writeJSONObject(obj, to: f)
        let again = try #require(try AtomicFile.readJSONObject(at: f))
        #expect((again["keep"] as? [String: Any])?["n"] as? Int == 1)
        #expect(try AtomicFile.readJSONObject(at: t.url.appending(path: "missing.json")) == nil)
    }

    @Test func safePath() throws {
        let t = TempDir()
        let root = t.url.appending(path: "root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SafePath.require(root.appending(path: "child"), within: [root])
        #expect(throws: SafePathError.self) { try SafePath.require(root, within: [root]) }
        #expect(throws: SafePathError.self) { try SafePath.require(t.url.appending(path: "other"), within: [root]) }
        #expect(throws: SafePathError.self) { try SafePath.require(URL(filePath: root.path + "/../escape"), within: [root]) }
        #expect(throws: SafePathError.self) { try SafePath.require(URL(filePath: root.path + "sibling/x"), within: [root]) }
        #expect(throws: SafePathError.self) { try SafePath.require(URL(filePath: "/etc/hosts"), within: [URL(filePath: "/")]) }
        // Symlinked parent pointing outside is rejected.
        let outside = t.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: outside)
        #expect(throws: SafePathError.self) { try SafePath.require(root.appending(path: "link/file"), within: [root]) }
        // The link itself (leaf) is inside.
        try SafePath.require(root.appending(path: "link"), within: [root])
        #expect(!SafePath.isSafeComponent("../x"))
        #expect(!SafePath.isSafeComponent(".."))
        #expect(SafePath.isSafeComponent("ext-1.2"))
    }
}

@Suite struct ProfileStoreTests {
    @Test func addUpdateRemovePreservesOrder() async throws {
        let t = TempDir()
        let store = ProfileStore(paths: t.paths)
        #expect(try await store.all().isEmpty)
        let a = Profile(name: "Work", color: .blue), b = Profile(name: "Home", color: .green), c = Profile(name: "Zed", color: .red)
        try await store.add(a); try await store.add(b); try await store.add(c)
        await #expect(throws: ProfileStoreError.duplicateID(a.id)) { try await store.add(a) }
        var b2 = b; b2.name = "House"
        try await store.update(b2)
        let fresh = ProfileStore(paths: t.paths)
        #expect(try await fresh.all().map(\.name) == ["Work", "House", "Zed"])
        try await fresh.reorder([c.id, a.id])
        #expect(try await fresh.all().map(\.name) == ["Zed", "Work", "House"])
        try await fresh.remove(id: a.id)
        #expect(try await ProfileStore(paths: t.paths).all().map(\.id) == [c.id, b.id])
        await #expect(throws: ProfileStoreError.notFound(a.id)) { try await fresh.remove(id: a.id) }
        try await fresh.update(id: c.id) { $0.showBorder = false }
        #expect(try await fresh.profile(id: c.id)?.showBorder == false)
    }

    @Test func runtimeState() async throws {
        let t = TempDir()
        let s = RuntimeStateStore(paths: t.paths)
        #expect(await s.settings() == AppSettings())
        let id = UUID()
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        try await s.markActive(id, at: d)
        try await s.updateSettings { $0.linkRoutingEnabled = true; $0.menuBarLetter = true }
        let fresh = RuntimeStateStore(paths: t.paths)
        let st = await fresh.state()
        #expect(st.lastActive(id) == d)
        #expect(st.lastActiveByID[id] == d)
        #expect(st.settings.linkRoutingEnabled && st.settings.menuBarLetter && !st.settings.onboardingCompleted)
        let synced = RuntimeStateStore.load(url: t.paths.stateJSON)
        #expect(synced == st)
        #expect(RuntimeStateStore.load(url: t.url.appending(path: "missing.json")) == RuntimeState())
        try await fresh.forget(id)
        #expect(await fresh.state().lastActive(id) == nil)
    }

    @Test func runtimeStateToleratesPartialAndCorrupt() async throws {
        let t = TempDir()
        t.write("Library/Application Support/Claude Multi Account/state.json", #"{"settings":{"musicPauseEnabled":true}}"#)
        #expect(await RuntimeStateStore(paths: t.paths).settings().musicPauseEnabled)
        t.write("Library/Application Support/Claude Multi Account/state.json", "{nope")
        #expect(await RuntimeStateStore(paths: t.paths).state() == RuntimeState())
    }
}

@Suite struct JournalTests {
    @Test func lifecycle() throws {
        let t = TempDir()
        let j = OperationJournal(paths: t.paths)
        #expect(j.pending().isEmpty)
        let e = try j.begin(.moveRegularClaude, payload: ["src": "/a b"], at: Date(timeIntervalSince1970: 1))
        let e2 = try j.advance(e, to: "renamed", payload: ["dst": "/c"])
        let p = j.pending()
        #expect(p.count == 1)
        #expect(p[0].step == "renamed")
        #expect(p[0].payload == ["src": "/a b", "dst": "/c"])
        #expect(p[0].kind == .moveRegularClaude)
        try j.complete(e2.id)
        #expect(j.pending().isEmpty)
        try j.complete(e2.id) // idempotent
    }
}
