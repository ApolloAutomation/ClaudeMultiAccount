import Foundation
import Testing
@testable import CMACore

@Suite struct NameValidatorTests {
    let a = Profile(name: "Work", color: .blue)

    @Test func rules() {
        #expect(NameValidator.validate("  ", existing: []) == .empty)
        #expect(NameValidator.validate(String(repeating: "x", count: 65), existing: []) == .tooLong)
        #expect(NameValidator.validate(String(repeating: "x", count: 64), existing: []) == nil)
        #expect(NameValidator.validate("a/b", existing: []) == .invalidCharacter)
        #expect(NameValidator.validate("a:b", existing: []) == .invalidCharacter)
        #expect(NameValidator.validate("a\nb", existing: []) == .invalidCharacter)
        #expect(NameValidator.validate(".hidden", existing: []) == .leadingDot)
        #expect(NameValidator.validate(" work ", existing: [a]) == .duplicate)
        #expect(NameValidator.validate("WORK", existing: [a], excluding: a.id) == nil)
        #expect(NameValidator.validate("Client's Work", existing: [a]) == nil)
        #expect(!NameValidationError.duplicate.message.isEmpty)
    }

    @Test func dedupe() {
        #expect(NameValidator.deduplicated("Work", taken: ["Home"]) == "Work")
        #expect(NameValidator.deduplicated("Work", taken: ["work", "Work 2"]) == "Work 3")
        let long = String(repeating: "x", count: 64)
        let d = NameValidator.deduplicated(long, taken: [long])
        #expect(d.count == 64 && d.hasSuffix(" 2"))
    }
}

@Suite struct SlugTests {
    @Test func slugs() {
        #expect(Slug.slug("Work") == "work")
        #expect(Slug.slug("  Client's Work!! ") == "client-s-work")
        #expect(Slug.slug("Café Ünïcode") == "cafe-unicode")
        #expect(Slug.slug("日本") == "profile")
        #expect(Slug.terminalCommand(for: "My Team") == "claude-my-team")
        #expect(Slug.slug(String(repeating: "ab ", count: 40)).count <= 40)
    }

    @Test func ids() {
        let id = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        #expect(Slug.id8(id) == "abcdef12")
        #expect(Slug.bundleIdentifier(for: id) == "com.apolloautomation.claudemultiaccount.profile.abcdef12")
        #expect(Profile(id: id, name: "x", color: .red).bundleIdentifier == Slug.bundleIdentifier(for: id))
        #expect(Slug.appName("Work") == "Claude (Work)")
        #expect(Slug.badgeLetter("work") == "W")
        #expect(Slug.badgeLetter("  émile") == "É")
        #expect(Slug.badgeLetter("!!") == "?")
    }
}

@Suite struct InfoPlistTests {
    @Test func makeParseStale() throws {
        let t = TempDir()
        var p = Profile(name: "Work Stuff", color: .teal, borderWidth: .thick)
        p.claudeConfigDir = "/x/y"
        let data = try ProfileInfoPlist.make(profile: p, paths: t.paths, agentHash: "abc")
        let raw = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(raw["CFBundleExecutable"] as? String == "ProfileAgent")
        #expect(raw["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(raw["LSUIElement"] as? Bool == true)
        #expect(raw["CFBundleName"] as? String == "Claude (Work Stuff)")
        #expect(raw["CFBundleIdentifier"] as? String == p.bundleIdentifier)
        #expect(raw["CMABuilderVersion"] as? Int == ProfileInfoPlist.builderVersion)
        #expect(raw["CMABorderWidth"] as? Int == 6)
        let parsed = try #require(ProfileInfoPlist.parse(data))
        #expect(parsed.profileID == p.id)
        #expect(parsed.userDataDir == t.paths.dataDir(for: p.id).path)
        #expect(parsed.claudeConfigDir == "/x/y")
        #expect(parsed.color == .teal)
        #expect(!ProfileInfoPlist.isStale(parsed, agentHash: "abc"))
        #expect(ProfileInfoPlist.isStale(parsed, agentHash: "def"))
        #expect(ProfileInfoPlist.isStale(parsed, agentHash: "abc", builderVersion: ProfileInfoPlist.builderVersion + 1))
        #expect(ProfileInfoPlist.isStale(nil, agentHash: "abc"))
        #expect(!parsed.differs(from: p, paths: t.paths))
        var renamed = p; renamed.name = "Other"
        #expect(parsed.differs(from: renamed, paths: t.paths))
    }

    @Test func optionalConfigDirOmittedAndBadPlist() throws {
        let t = TempDir()
        let p = Profile(name: "A", color: .orange)
        let d = ProfileInfoPlist(profile: p, paths: t.paths, agentHash: "h").dictionary()
        #expect(d["CMAClaudeConfigDir"] == nil)
        #expect(ProfileInfoPlist.parse(Data("junk".utf8)) == nil)
        #expect(ProfileInfoPlist(dictionary: ["CMAProfileID": "nope"]) == nil)
    }
}
