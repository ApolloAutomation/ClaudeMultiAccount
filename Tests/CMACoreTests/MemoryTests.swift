import Foundation
import Testing
@testable import CMACore

@Suite struct MemoryTests {
    let note = "---\nname: Use tabs\ndescription: \"Formatting rule\"\ntype: feedback\n---\n\nAlways use tabs.\n"

    @Test func frontmatter() {
        let (f, body) = Frontmatter.parse(note)
        #expect(f == ["name": "Use tabs", "description": "Formatting rule", "type": "feedback"])
        #expect(body == "Always use tabs.\n")
        #expect(Frontmatter.parse("no front\n").fields.isEmpty)
        #expect(Frontmatter.parse("---\nname: x\nunterminated").body == "---\nname: x\nunterminated")
        #expect(Frontmatter.parse("---\r\nname: y\r\n---\r\nb").fields["name"] == "y")
    }

    @Test func listing() {
        let t = TempDir()
        let s = MemoryStore(claudeDir: t.url.appending(path: ".claude"))
        t.write(".claude/projects/-Users-x-my-app/memory/tabs.md", note)
        t.write(".claude/projects/-Users-x-my-app/memory/MEMORY.md", "- [Use tabs](tabs.md)\n")
        t.write(".claude/projects/-Users-x-my-app/abc.jsonl", "{\"type\":\"summary\"}\n{\"cwd\":\"/Users/x/my.app\",\"x\":1}\n")
        t.write(".claude/projects/-Users-y-empty/zzz.jsonl", "{}")
        t.write(".claude/projects/-Users-z-nolog/memory/n.md", "plain")
        t.write(".claude/CLAUDE.md", "a\nb\nc\n")
        let ps = s.projects()
        #expect(ps.map(\.dirName) == ["-Users-x-my-app", "-Users-z-nolog"])
        #expect(ps[0].displayPath == "/Users/x/my.app")
        #expect(ps[0].notes.map(\.fileName) == ["tabs.md"])
        #expect(ps[0].notes[0].title == "Use tabs")
        #expect(ps[1].displayPath == "/Users/z/nolog")
        #expect(ps[1].notes[0].title == "n")
        #expect(s.projects(includeEmpty: true).count == 3)
        #expect(s.generalRulesLineCount() == 3)
    }

    @Test func copyResolutions() throws {
        let t = TempDir()
        t.write("src/memory/tabs.md", note)
        t.write("src/memory/other.md", "---\nname: Other\n---\nbody")
        t.write("dst/memory/tabs.md", "OLD")
        t.write("dst/memory/MEMORY.md", "- [Old](tabs.md) — old\n")
        let notes = [MemoryStore.loadNote(t.url.appending(path: "src/memory/tabs.md"), project: "src")!,
                     MemoryStore.loadNote(t.url.appending(path: "src/memory/other.md"), project: "src")!]
        let dst = t.url.appending(path: "dst/memory"), bk = t.url.appending(path: "bk")

        let skip = try MemoryOps.copy(notes, toMemoryDir: dst, backupDir: bk) { _ in .skip }
        #expect(skip.skipped == ["tabs.md"])
        #expect(t.read("dst/memory/tabs.md") == "OLD")
        #expect(t.read("dst/memory/MEMORY.md") == "- [Old](tabs.md) — old\n- [Other](other.md)\n")

        let both = try MemoryOps.copy([notes[0]], toMemoryDir: dst, backupDir: bk) { _ in .keepBoth }
        #expect(both.written.map(\.lastPathComponent) == ["tabs 2.md"])
        #expect(t.read("dst/memory/tabs.md") == "OLD")
        #expect(t.read("dst/memory/MEMORY.md")?.contains("- [Use tabs](tabs 2.md) — Formatting rule") == true)

        let rep = try MemoryOps.copy([notes[0]], toMemoryDir: dst, backupDir: bk) { _ in .replace }
        #expect(t.read("dst/memory/tabs.md") == note)
        #expect(rep.backedUp.count == 1)
        #expect(try String(contentsOf: rep.backedUp[0], encoding: .utf8) == "OLD")
    }

    @Test func generalRulesIdempotent() throws {
        let t = TempDir()
        let md = t.write("CLAUDE.md", "# My rules\n\nBe nice.\n")
        let n = MemoryStore.loadNote(t.write("p/memory/tabs.md", note), project: "proj")!
        let bk = t.url.appending(path: "bk")
        #expect(try MemoryOps.makeGeneralRules([n], claudeMD: md, backupDir: bk) == 1)
        let once = try #require(t.read("CLAUDE.md"))
        #expect(once.contains("# My rules\n\nBe nice.\n\n# Rules shared from project memory\n\n## Use tabs\n<!-- cma:proj/tabs.md -->\nAlways use tabs.\n"))
        #expect(try MemoryOps.makeGeneralRules([n, n], claudeMD: md, backupDir: bk) == 0)
        #expect(t.read("CLAUDE.md") == once)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bk.path).count == 1)
    }

    @Test func rulesInsertedUnderExistingHeading() {
        let n2 = MemoryNote(url: URL(filePath: "/x"), project: "p", fileName: "b.md", name: "B", description: "", type: nil, body: "bee\n", raw: "")
        let existing = "# Rules shared from project memory\n\n## A\n<!-- cma:p/a.md -->\nay\n\n# Later\nkeep\n"
        let (text, added) = MemoryOps.appendingRules(existing, notes: [n2])
        #expect(added == 1)
        #expect(text == "# Rules shared from project memory\n\n## A\n<!-- cma:p/a.md -->\nay\n\n## B\n<!-- cma:p/b.md -->\nbee\n\n# Later\nkeep\n")
        let fromEmpty = MemoryOps.appendingRules("", notes: [n2]).text
        #expect(fromEmpty == "# Rules shared from project memory\n\n## B\n<!-- cma:p/b.md -->\nbee\n")
    }

    @Test func indexLine() {
        #expect(MemoryOps.indexLine(title: "T", fileName: "t.md", description: "d") == "- [T](t.md) — d")
        #expect(MemoryOps.addingIndexLine("- [T](t.md)", title: "T", fileName: "t.md", description: "") == "- [T](t.md)")
    }
}
