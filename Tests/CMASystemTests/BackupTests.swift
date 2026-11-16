import Foundation
import Testing
@testable import CMACore
@testable import CMASystem

@Suite struct BackupTests {
    @Test func exportRestoreRoundTripExcludesCaches() async throws {
        let t = TempDir()
        let p = Profile(name: "Work", color: .purple)
        let root = "Library/Application Support/Claude Multi Account/Profiles/\(p.id.uuidString)"
        t.write("\(root)/config.json", #"{"lastKnownAccountUuid":"acc"}"#)
        t.write("\(root)/Local Storage/leveldb/000003.log", "data")
        t.write("\(root)/claude-code-sessions/acc/org/local_1.json", "{}")
        t.write("\(root)/Cache/Cache_Data/blob", "cache")
        t.write("\(root)/Code Cache/js/x", "cache")
        t.write("\(root)/Crashpad/report", "crash")
        try FileManager.default.createSymbolicLink(atPath: t.url.appending(path: "\(root)/SingletonLock").path,
                                                   withDestinationPath: "host-123")
        let a = BackupArchiver(paths: t.paths)
        let zipURL = t.url.appending(path: "out/backup.zip")
        try await a.export(p, to: zipURL)

        let names = try a.listEntries(zipURL)
        #expect(names.contains("manifest.json"))
        #expect(names.contains("\(p.id.uuidString)/config.json"))
        #expect(!names.contains { $0.contains("Cache") || $0.contains("Crashpad") || $0.contains("Singleton") })

        let restored = try await a.restore(from: zipURL, existingNames: ["Work"])
        #expect(restored.id != p.id)
        #expect(restored.name == "Work 2")
        #expect(restored.color == .purple)
        let newDir = t.paths.dataDir(for: restored.id)
        let snap = treeSnapshot(newDir)
        #expect(snap["config.json"] == Data(#"{"lastKnownAccountUuid":"acc"}"#.utf8))
        #expect(snap["Local Storage/leveldb/000003.log"] == Data("data".utf8))
        #expect(snap["claude-code-sessions/acc/org/local_1.json"] == Data("{}".utf8))
        #expect(!snap.keys.contains { $0.hasPrefix("Cache") || $0.hasPrefix("Crashpad") })
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: t.paths.buildDir.path)) ?? []).isEmpty)
    }

    @Test func emptyProfileExports() async throws {
        let t = TempDir()
        let p = Profile(name: "Empty", color: .gray)
        try FileManager.default.createDirectory(at: t.paths.dataDir(for: p.id), withIntermediateDirectories: true)
        let a = BackupArchiver(paths: t.paths)
        let z = t.url.appending(path: "e.zip")
        try await a.export(p, to: z)
        let r = try await a.restore(from: z, existingNames: [])
        #expect(r.name == "Empty")
        #expect(FileManager.default.fileExists(atPath: t.paths.dataDir(for: r.id).path))
    }

    /// Writes a zip with arbitrary entry names / symlinks using Python's zipfile (isolated mode).
    func craftZip(_ t: TempDir, entries: [(name: String, content: String, symlink: Bool)]) throws -> URL {
        let out = t.url.appending(path: "evil-\(UUID().uuidString).zip")
        let spec = t.url.appending(path: "spec-\(UUID().uuidString).json")
        let arr = entries.map { ["name": $0.name, "content": $0.content, "symlink": $0.symlink] as [String: Any] }
        try JSONSerialization.data(withJSONObject: arr).write(to: spec)
        let script = """
        import json, sys, zipfile
        spec = json.load(open(sys.argv[1]))
        with zipfile.ZipFile(sys.argv[2], 'w') as z:
            for e in spec:
                info = zipfile.ZipInfo(e['name'])
                info.create_system = 3
                info.external_attr = ((0o120777 if e['symlink'] else 0o100644) << 16)
                z.writestr(info, e['content'])
        """
        let r = try Subprocess.runSync(URL(fileURLWithPath: "/usr/bin/python3"), ["-I", "-c", script, spec.path, out.path])
        #expect(r.succeeded, "\(r.stderrString)")
        return out
    }

    @Test func maliciousZipsRejected() async throws {
        let t = TempDir()
        let a = BackupArchiver(paths: t.paths)
        let id = UUID().uuidString
        let manifest = String(decoding: try BackupManifest(profile: Profile(name: "X", color: .red)).encoded(), as: UTF8.self)

        let traversal = try craftZip(t, entries: [("manifest.json", manifest, false), ("\(id)/a", "x", false), ("\(id)/../../evil", "x", false)])
        await #expect(throws: BackupError.self) { try await a.restore(from: traversal, existingNames: []) }

        let absolute = try craftZip(t, entries: [("manifest.json", manifest, false), ("/tmp/evil", "x", false)])
        await #expect(throws: BackupError.self) { try await a.restore(from: absolute, existingNames: []) }

        let twoRoots = try craftZip(t, entries: [("manifest.json", manifest, false), ("\(id)/a", "x", false), ("\(UUID().uuidString)/b", "x", false)])
        await #expect(throws: BackupError.self) { try await a.restore(from: twoRoots, existingNames: []) }

        let linkSlip = try craftZip(t, entries: [("manifest.json", manifest, false), ("\(id)/link", t.url.path, true), ("\(id)/link/pwned", "x", false)])
        await #expect(throws: BackupError.self) { try await a.restore(from: linkSlip, existingNames: []) }

        let linkOut = try craftZip(t, entries: [("manifest.json", manifest, false), ("\(id)/link", "/etc", true)])
        await #expect(throws: BackupError.self) { try await a.restore(from: linkOut, existingNames: []) }

        var future = BackupManifest(profile: Profile(name: "X", color: .red))
        future.formatVersion = 99
        let fz = try craftZip(t, entries: [("manifest.json", String(decoding: try future.encoded(), as: UTF8.self), false), ("\(id)/a", "x", false)])
        await #expect(throws: BackupError.unsupportedVersion(99)) { try await a.restore(from: fz, existingNames: []) }

        #expect(!t.exists("pwned") && !t.exists("evil"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: t.paths.profilesDir.path)) ?? []).isEmpty)
    }
}
