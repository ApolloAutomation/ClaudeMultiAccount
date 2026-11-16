import Foundation
@testable import CMACore

final class TempDir: @unchecked Sendable {
    let url: URL
    init() {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        url = base.appending(path: "cma-systests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    var paths: AppPaths { AppPaths(home: url) }

    @discardableResult
    func write(_ rel: String, _ text: String) -> URL {
        let u = url.appending(path: rel)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: u)
        return u
    }
    @discardableResult
    func writeJSON(_ rel: String, _ obj: Any) -> URL {
        write(rel, String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: .sortedKeys), as: UTF8.self))
    }
    func data(_ rel: String) -> Data? { try? Data(contentsOf: url.appending(path: rel)) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url.appending(path: rel).path) }
}

/// Snapshot of every file (relative path → bytes / link target) under a directory.
func treeSnapshot(_ root: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    let fm = FileManager.default
    guard let e = fm.enumerator(atPath: root.path) else { return out }
    for case let rel as String in e {
        let p = root.appending(path: rel).path
        if let dest = try? fm.destinationOfSymbolicLink(atPath: p) { out[rel] = Data(("link:" + dest).utf8); continue }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue { out[rel] = fm.contents(atPath: p) ?? Data() }
    }
    return out
}
