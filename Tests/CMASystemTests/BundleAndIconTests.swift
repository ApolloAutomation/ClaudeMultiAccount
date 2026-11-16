import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CMACore
@testable import CMASystem

@Suite struct IconTests {
    @Test func icnsIsValid() throws {
        let data = try IconRenderer.icnsData(letter: "Work", color: .blue)
        #expect(data.prefix(4) == Data("icns".utf8))
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(src) as String? == "com.apple.icns")
        #expect(CGImageSourceGetCount(src) >= 1)
        let png = try IconRenderer.pngData(letter: "w", color: .orange, size: 256)
        let img = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(img.width == 256 && img.height == 256)
    }
}

@Suite struct BundleBuilderTests {
    func builder(_ t: TempDir) throws -> BundleBuilder {
        let agent = t.url.appending(path: "agent/ProfileAgent")
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: agent)
        return BundleBuilder(paths: t.paths, agentBinary: agent, lsregister: nil)
    }

    @Test func buildsSignedBundleWithParsablePlist() async throws {
        let t = TempDir()
        let b = try builder(t)
        var p = Profile(name: "Work", color: .green)
        #expect(try b.needsRebuild(p))
        let app = try await b.build(p)
        #expect(app == t.paths.appURL(forName: "Work"))
        let verify = try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", app.path])
        #expect(verify.succeeded, "\(verify.stderrString)")
        let plist = try #require(ProfileInfoPlist.read(appURL: app))
        #expect(plist.profileID == p.id)
        #expect(plist.profileName == "Work")
        #expect(plist.agentHash == (try b.agentHash()))
        #expect(plist.userDataDir == t.paths.dataDir(for: p.id).path)
        #expect(FileManager.default.fileExists(atPath: app.appending(path: "Contents/Resources/ProfileIcon.icns").path))
        #expect(FileManager.default.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/ProfileAgent").path))
        #expect(try !b.needsRebuild(p))
        // No leftovers in Build/.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: t.paths.buildDir.path)) ?? []).isEmpty)

        // Rebuild in place (color change) then rename.
        p.color = .red
        #expect(try b.needsRebuild(p))
        try await b.build(p)
        #expect(ProfileInfoPlist.read(appURL: app)?.color == .red)
        let old = b.appURL(for: p)
        p.name = "Personal"
        let renamed = try await b.build(p, previousAppURL: old)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(ProfileInfoPlist.read(appURL: renamed)?.profileName == "Personal")
        try await b.remove(p)
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test func removeRefusesOutsideAppsDir() async throws {
        let t = TempDir()
        let b = try builder(t)
        let outside = t.url.appending(path: "Other.app")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        await #expect(throws: SafePathError.self) { try await b.remove(appURL: outside) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}

@Suite struct SubprocessTests {
    @Test func capturesOutputAndStatus() async throws {
        let r = try await Subprocess.run(URL(fileURLWithPath: "/bin/echo"), ["a b", "$HOME"])
        #expect(r.stdoutString == "a b $HOME\n")
        let f = try await Subprocess.run(URL(fileURLWithPath: "/bin/ls"), ["/definitely/not/here"])
        #expect(f.status != 0 && !f.stderr.isEmpty)
        await #expect(throws: SubprocessError.self) {
            try await Subprocess.checked(URL(fileURLWithPath: "/usr/bin/false"), [])
        }
        await #expect(throws: SubprocessError.timedOut(path: "/bin/sleep")) {
            try await Subprocess.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: .milliseconds(200))
        }
    }
}
