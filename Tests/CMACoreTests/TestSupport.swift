import Foundation
@testable import CMACore

/// Unique temp dir; removed on deinit.
final class TempDir: @unchecked Sendable {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "cma-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        write(rel, String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self))
    }
    func read(_ rel: String) -> String? { try? String(contentsOf: url.appending(path: rel), encoding: .utf8) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url.appending(path: rel).path) }
}
