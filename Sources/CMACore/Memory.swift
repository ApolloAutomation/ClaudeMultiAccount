import Foundation

public struct MemoryNote: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { "\(project)/\(fileName)" }
    public var url: URL
    /// Encoded project directory name.
    public var project: String
    public var fileName: String
    public var name: String
    public var description: String
    public var type: String?
    public var body: String
    /// Whole file text.
    public var raw: String

    public var title: String { name.isEmpty ? String(fileName.dropLast(fileName.hasSuffix(".md") ? 3 : 0)) : name }
}

public struct MemoryProject: Sendable, Equatable, Identifiable {
    public var id: String { dirName }
    public var dirName: String
    public var displayPath: String
    public var dir: URL
    public var memoryDir: URL { dir.appending(path: "memory", directoryHint: .isDirectory) }
    public var notes: [MemoryNote]
}

public enum Frontmatter {
    /// Parses a leading `---` YAML block of simple `key: value` lines. No frontmatter → empty fields, whole text as body.
    public static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], normalized) }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], normalized)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            if !k.isEmpty { fields[k] = v }
        }
        lines.removeSubrange(0...end)
        var body = lines.joined(separator: "\n")
        while body.hasPrefix("\n") { body.removeFirst() }
        return (fields, body)
    }
}

/// Read-only view of `~/.claude` memory.
public struct MemoryStore: Sendable {
    public static let indexFileName = "MEMORY.md"
    public let claudeDir: URL
    public init(claudeDir: URL) { self.claudeDir = claudeDir }
    public init(paths: AppPaths) { claudeDir = paths.claudeConfigDir }

    public var generalRulesURL: URL { claudeDir.appending(path: "CLAUDE.md") }
    public var projectsDir: URL { claudeDir.appending(path: "projects", directoryHint: .isDirectory) }

    public func generalRulesLineCount() -> Int {
        guard let s = try? String(contentsOf: generalRulesURL, encoding: .utf8), !s.isEmpty else { return 0 }
        var n = s.split(separator: "\n", omittingEmptySubsequences: false).count
        if s.hasSuffix("\n") { n -= 1 }
        return n
    }

    public static func loadNote(_ url: URL, project: String) -> MemoryNote? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (f, body) = Frontmatter.parse(raw)
        return MemoryNote(url: url, project: project, fileName: url.lastPathComponent, name: f["name"] ?? "",
                          description: f["description"] ?? "", type: f["type"], body: body, raw: raw)
    }

    /// All project dirs (including those without memory notes when `includeEmpty`).
    public func projects(includeEmpty: Bool = false) -> [MemoryProject] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: projectsDir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        var out: [MemoryProject] = []
        for name in names {
            let dir = projectsDir.appending(path: name, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let mem = dir.appending(path: "memory", directoryHint: .isDirectory)
            let files = ((try? fm.contentsOfDirectory(atPath: mem.path)) ?? [])
                .filter { $0.hasSuffix(".md") && $0 != Self.indexFileName && !$0.hasPrefix(".") }.sorted()
            let notes = files.compactMap { Self.loadNote(mem.appending(path: $0), project: name) }
            if notes.isEmpty && !includeEmpty { continue }
            out.append(MemoryProject(dirName: name, displayPath: Self.displayPath(projectDir: dir), dir: dir, notes: notes))
        }
        return out
    }

    /// `cwd` from the first transcript line that has one; falls back to a lossy decode of the dir name.
    public static func displayPath(projectDir: URL) -> String {
        let fm = FileManager.default
        let jsonl = ((try? fm.contentsOfDirectory(atPath: projectDir.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
        for f in jsonl {
            guard let h = try? FileHandle(forReadingFrom: projectDir.appending(path: f)) else { continue }
            let data = (try? h.read(upToCount: 256 * 1024)) ?? Data()
            try? h.close()
            for line in data.split(separator: UInt8(ascii: "\n")).prefix(20) {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    return cwd
                }
            }
        }
        return lossyDecode(projectDir.lastPathComponent)
    }

    public static func lossyDecode(_ dirName: String) -> String {
        dirName.replacingOccurrences(of: "-", with: "/")
    }
}

public enum ConflictResolution: Sendable, Equatable { case replace, keepBoth, skip }

public struct MemoryCopyResult: Sendable, Equatable {
    public var written: [URL] = []
    public var skipped: [String] = []
    public var backedUp: [URL] = []
}

public enum MemoryOps {
    public static let rulesHeading = "# Rules shared from project memory"

    public static func marker(project: String, file: String) -> String { "<!-- cma:\(project)/\(file) -->" }

    public static func indexLine(title: String, fileName: String, description: String) -> String {
        let t = title.replacingOccurrences(of: "\n", with: " ")
        let d = description.replacingOccurrences(of: "\n", with: " ")
        return d.isEmpty ? "- [\(t)](\(fileName))" : "- [\(t)](\(fileName)) — \(d)"
    }

    /// Adds an index line unless `fileName` is already linked.
    public static func addingIndexLine(_ index: String, title: String, fileName: String, description: String) -> String {
        if index.contains("](\(fileName))") { return index }
        var s = index
        if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
        return s + indexLine(title: title, fileName: fileName, description: description) + "\n"
    }

    /// `note.md` → `note 2.md`, `note 3.md`… first free name in `dir`.
    public static func uniqueFileName(_ name: String, in dir: URL) -> String {
        let fm = FileManager.default
        let base = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        var i = 2
        while true {
            let candidate = "\(base) \(i).md"
            if !fm.fileExists(atPath: dir.appending(path: candidate).path) { return candidate }
            i += 1
        }
    }

    static func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    static func backup(_ url: URL, into dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appending(path: uniqueFileName(url.lastPathComponent, in: dir))
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    /// Copies notes into `destinationMemoryDir`, updating its MEMORY.md. Replaced files are backed up into `backupDir`.
    public static func copy(_ notes: [MemoryNote], toMemoryDir destinationMemoryDir: URL, backupDir: URL,
                            resolve: (MemoryNote) -> ConflictResolution) throws -> MemoryCopyResult {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationMemoryDir, withIntermediateDirectories: true)
        var result = MemoryCopyResult()
        let indexURL = destinationMemoryDir.appending(path: MemoryStore.indexFileName)
        var index = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
        let originalIndex = index
        for note in notes {
            guard SafePath.isSafeComponent(note.fileName), note.fileName != MemoryStore.indexFileName else {
                result.skipped.append(note.fileName); continue
            }
            var fileName = note.fileName
            let dest = destinationMemoryDir.appending(path: fileName)
            if dest.standardizedFileURL == note.url.standardizedFileURL { result.skipped.append(fileName); continue }
            if fm.fileExists(atPath: dest.path) {
                switch resolve(note) {
                case .skip:
                    result.skipped.append(fileName); continue
                case .replace:
                    result.backedUp.append(try backup(dest, into: backupDir))
                case .keepBoth:
                    fileName = uniqueFileName(fileName, in: destinationMemoryDir)
                }
            }
            let target = destinationMemoryDir.appending(path: fileName)
            try AtomicFile.write(note.raw, to: target)
            result.written.append(target)
            index = addingIndexLine(index, title: note.title, fileName: fileName, description: note.description)
        }
        if index != originalIndex {
            if fm.fileExists(atPath: indexURL.path) { result.backedUp.append(try backup(indexURL, into: backupDir)) }
            try AtomicFile.write(index, to: indexURL)
        }
        return result
    }

    /// Pure: appends each note (not yet present by marker) under the rules heading. Returns new text and added count.
    public static func appendingRules(_ existing: String, notes: [MemoryNote]) -> (text: String, added: Int) {
        var blocks: [String] = []
        var seen = Set<String>()
        for n in notes {
            let m = marker(project: n.project, file: n.fileName)
            if existing.contains(m) || !seen.insert(m).inserted { continue }
            var body = n.body
            while body.hasSuffix("\n") { body.removeLast() }
            blocks.append("## \(n.title)\n\(m)\n\(body)\n")
        }
        guard !blocks.isEmpty else { return (existing, 0) }
        let insertion = blocks.joined(separator: "\n")
        var lines = existing.components(separatedBy: "\n")
        if let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == rulesHeading }) {
            // End of the heading's section = next level-1 heading, else end of file.
            let next = lines[(h + 1)...].firstIndex(where: { $0.hasPrefix("# ") }) ?? lines.count
            var before = Array(lines[..<next])
            while let last = before.last, last.trimmingCharacters(in: .whitespaces).isEmpty, before.count > h + 1 { before.removeLast() }
            let after = Array(lines[next...])
            var text = before.joined(separator: "\n") + "\n\n" + insertion
            if !after.isEmpty && !(after.count == 1 && after[0].isEmpty) { text += "\n" + after.joined(separator: "\n") }
            return (text, blocks.count)
        }
        lines = []
        var text = existing
        if !text.isEmpty {
            while text.hasSuffix("\n") { text.removeLast() }
            text += "\n\n"
        }
        text += rulesHeading + "\n\n" + insertion
        return (text, blocks.count)
    }

    /// Appends notes to CLAUDE.md (backup first). Idempotent via markers. Returns number of rules added.
    @discardableResult
    public static func makeGeneralRules(_ notes: [MemoryNote], claudeMD: URL, backupDir: URL) throws -> Int {
        let existing = (try? String(contentsOf: claudeMD, encoding: .utf8)) ?? ""
        let (text, added) = appendingRules(existing, notes: notes)
        guard added > 0 else { return 0 }
        if FileManager.default.fileExists(atPath: claudeMD.path) { _ = try backup(claudeMD, into: backupDir) }
        try AtomicFile.write(text, to: claudeMD)
        return added
    }

    public static func backupDir(paths: AppPaths, date: Date = Date()) -> URL {
        paths.backupsDir.appending(path: "memory/\(timestamp(date))", directoryHint: .isDirectory)
    }
}
