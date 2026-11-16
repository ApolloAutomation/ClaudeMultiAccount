import Foundation
import Testing
@testable import CMACore

@Suite struct SettingsImportTests {
    @Test func missingOnlyMerge() throws {
        let t = TempDir()
        t.writeJSON("src/claude_desktop_config.json", ["mcpServers": ["a": ["command": "x"], "b": ["command": "y"]],
                                                       "preferences": ["p1": true, "p2": false], "extra": 1, "oauthThing": "no"])
        t.writeJSON("dst/claude_desktop_config.json", ["mcpServers": ["a": ["command": "KEEP"]], "preferences": ["p1": false], "mine": 2])
        t.write("src/developer_settings.json", "{}")
        t.writeJSON("src/extensions-installations.json", ["extensions": ["ext.one": ["v": 1], "ext.two": ["v": 2], "../evil": ["v": 3]]])
        t.writeJSON("dst/extensions-installations.json", ["extensions": ["ext.two": ["v": 9]], "other": true])
        t.write("src/Claude Extensions/ext.one/manifest.json", "{}")
        t.write("src/Claude Extensions Settings/ext.one.json", "{}")
        t.writeJSON("src/config.json", ["oauth:tokenCache": "SECRET", "lastKnownAccountUuid": "u", "darkMode": true, "scale": 1.25, "locale": "de-DE", "other": 1])
        t.writeJSON("dst/config.json", ["oauth:tokenCache": "DEST", "locale": "en-US"])

        let plan = try SettingsImportPlanner.plan(from: ClaudeDataDir(t.url.appending(path: "src")), to: ClaudeDataDir(t.url.appending(path: "dst")))
        #expect(plan.addedMCPServers == ["b"])
        #expect(plan.addedPreferences == ["p2"])
        #expect(plan.addedTopLevelKeys == ["extra"])
        #expect(plan.copiesDeveloperSettings)
        #expect(plan.addedExtensions == ["ext.one"])
        // Theme import was dropped: config.json is never a write, copy or backup target.
        #expect(!plan.writes.contains { $0.destination.lastPathComponent == "config.json" })
        #expect(!plan.copies.contains { $0.destination.lastPathComponent == "config.json" })
        #expect(plan.copies.count == 3)

        let cfgWrite = try #require(plan.writes.first { $0.destination.lastPathComponent == "claude_desktop_config.json" })
        let cfg = try #require(try JSONSerialization.jsonObject(with: cfgWrite.data) as? [String: Any])
        #expect(((cfg["mcpServers"] as? [String: Any])?["a"] as? [String: Any])?["command"] as? String == "KEEP")
        #expect(cfg["mine"] as? Int == 2)
        #expect(cfg["oauthThing"] == nil)
        let extWrite = try #require(plan.writes.first { $0.destination.lastPathComponent == "extensions-installations.json" })
        let ext = try #require(try JSONSerialization.jsonObject(with: extWrite.data) as? [String: Any])
        #expect(ext["other"] as? Bool == true)
        #expect(((ext["extensions"] as? [String: Any])?["ext.two"] as? [String: Any])?["v"] as? Int == 9)
        #expect((ext["extensions"] as? [String: Any])?["../evil"] == nil)
        // Nothing in the plan carries any config.json content.
        for w in plan.writes { #expect(!String(decoding: w.data, as: UTF8.self).contains("SECRET")) }
    }

    @Test func noopAndCorruptDest() throws {
        let t = TempDir()
        t.writeJSON("src/claude_desktop_config.json", ["preferences": ["p": 1]])
        t.write("dst/claude_desktop_config.json", "{corrupt")
        let plan = try SettingsImportPlanner.plan(from: ClaudeDataDir(t.url.appending(path: "src")), to: ClaudeDataDir(t.url.appending(path: "dst")))
        #expect(plan.isEmpty)
        // Desktop config absent in dest: created from source, mcpServers absent OK.
        let t2 = TempDir()
        t2.writeJSON("src/claude_desktop_config.json", ["preferences": ["p": 1]])
        let p2 = try SettingsImportPlanner.plan(from: ClaudeDataDir(t2.url.appending(path: "src")), to: ClaudeDataDir(t2.url.appending(path: "dst")))
        #expect(p2.addedPreferences == ["p"])
        #expect(p2.addedMCPServers.isEmpty)
    }
}
