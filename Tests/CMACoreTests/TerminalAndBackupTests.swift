import Foundation
import Testing
@testable import CMACore

@Suite struct TerminalScriptTests {
    @Test func quoting() {
        #expect(TerminalScript.shellQuote("abc") == "'abc'")
        #expect(TerminalScript.shellQuote("a b") == "'a b'")
        #expect(TerminalScript.shellQuote("it's") == #"'it'\''s'"#)
        #expect(TerminalScript.shellQuote("$HOME `x`") == "'$HOME `x`'")
    }

    @Test func renderAndRunWithSh() throws {
        let t = TempDir()
        let home = t.url.appending(path: "Ho me's", directoryHint: .isDirectory)
        let id = UUID()
        let configDir = home.appending(path: "Library/Application Support/Claude Multi Account/CLI/\(id.uuidString)")
        let s = TerminalScript.render(profileID: id, profileName: "O'Neil\nTeam", configDir: configDir, home: home)
        #expect(s.hasPrefix("#!/bin/sh\n"))
        #expect(s.contains(TerminalScript.marker(id)))
        #expect(!s.contains("O'Neil\nTeam"))
        #expect(s.contains("exit 127"))
        #expect(TerminalScript.isOwned(s))
        #expect(TerminalScript.isOwned(s, profileID: id))
        #expect(!TerminalScript.isOwned(s, profileID: UUID()))
        #expect(!TerminalScript.isOwned("#!/bin/sh\nexec claude\n"))

        // Not found → 127.
        let script = t.write("script", s)
        func run(_ args: [String]) throws -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(filePath: "/bin/sh")
            p.arguments = [script.path] + args
            p.environment = ["PATH": "/usr/bin:/bin"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        #expect(try run([]).0 == 127)

        // Candidate in a path with spaces and a quote gets exec'd with args and env.
        let fake = home.appending(path: ".local/bin/claude")
        try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s|' \"$CLAUDE_CONFIG_DIR\" \"$@\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let (code, out) = try run(["a b", "c'd"])
        #expect(code == 0)
        #expect(out == "\(configDir.path)|a b|c'd|")
    }

    @Test func installCheck() throws {
        let t = TempDir()
        let id = UUID()
        let u = t.url.appending(path: "claude-work")
        #expect(TerminalScript.check(u, profileID: id) == .free)
        try "#!/bin/sh\necho hi\n".write(to: u, atomically: true, encoding: .utf8)
        #expect(TerminalScript.check(u, profileID: id) == .foreign)
        let other = UUID()
        try TerminalScript.render(profileID: other, profileName: "x", configDir: t.url, home: t.url).write(to: u, atomically: true, encoding: .utf8)
        #expect(TerminalScript.check(u, profileID: id) == .ownedByOtherProfile)
        #expect(TerminalScript.check(u, profileID: other) == .ownedBySameProfile)
        let link = t.url.appending(path: "claude-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: u)
        #expect(TerminalScript.check(link, profileID: other) == .foreign)
        #expect(TerminalScript.installURL(binDir: t.paths.localBinDir, profileName: "My Team").lastPathComponent == "claude-my-team")
        let links = TerminalScript.seedLinks(profileID: id, paths: t.paths)
        #expect(links.count == 6)
        #expect(links[0].target == t.paths.claudeConfigDir.appending(path: "CLAUDE.md"))
        #expect(TerminalScript.candidates(home: t.url).count == 5)
    }
}

@Suite struct BackupTests {
    let root = "0F0E0D0C-0B0A-0908-0706-050403020100"

    @Test func validEntries() throws {
        #expect(try BackupEntryValidator.validate(["manifest.json", "\(root)/", "\(root)/config.json", "\(root)/Local Storage/x y"]) == root)
    }

    @Test func zipSlip() {
        #expect(throws: BackupEntryError.absolutePath("/etc/passwd")) { try BackupEntryValidator.validate(["manifest.json", "/etc/passwd"]) }
        #expect(throws: BackupEntryError.parentTraversal("\(root)/../../x")) { try BackupEntryValidator.validate(["manifest.json", "\(root)/../../x"]) }
        #expect(throws: BackupEntryError.parentTraversal("../x")) { try BackupEntryValidator.validate(["manifest.json", "../x"]) }
        #expect(throws: BackupEntryError.self) { try BackupEntryValidator.validate(["manifest.json", "\(root)\\..\\x"]) }
        #expect(throws: BackupEntryError.self) { try BackupEntryValidator.validate(["manifest.json", "~/x"]) }
        #expect(throws: BackupEntryError.self) { try BackupEntryValidator.validate(["manifest.json", "\(root)/a", "\(UUID().uuidString)/b"]) }
        #expect(throws: BackupEntryError.unexpectedTopLevel("evil.sh")) { try BackupEntryValidator.validate(["manifest.json", "\(root)/a", "evil.sh"]) }
        #expect(throws: BackupEntryError.missingManifest) { try BackupEntryValidator.validate(["\(root)/a"]) }
        #expect(throws: BackupEntryError.missingDataRoot) { try BackupEntryValidator.validate(["manifest.json"]) }
        #expect(throws: BackupEntryError.empty) { try BackupEntryValidator.validate([]) }
        #expect(throws: BackupEntryError.unexpectedTopLevel("notauuid")) { try BackupEntryValidator.validate(["manifest.json", "notauuid/a"]) }
        #expect(throws: BackupEntryError.self) { try BackupEntryValidator.validate(["manifest.json", "\(root)//a"]) }
    }

    @Test func manifestRoundTrip() throws {
        let p = Profile(name: "Work", color: .purple, showBorder: false, borderWidth: .medium)
        let m = BackupManifest(profile: p, createdAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "1.2")
        let back = try BackupManifest.decode(m.encoded())
        #expect(back == m)
        #expect(back.isSupported)
        var future = m; future.formatVersion = 2
        #expect(!future.isSupported)
        let restored = m.restoredProfile(existingNames: ["work"])
        #expect(restored.name == "Work 2")
        #expect(restored.id != p.id)
        #expect(restored.color == .purple && !restored.showBorder && restored.borderWidth == .medium)
    }
}
