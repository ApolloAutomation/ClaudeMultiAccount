import AppKit
import Foundation

/// Watches one Claude main process and calls `onExit` once when it terminates.
@MainActor
final class ClaudeSession {
    let pid: Int32
    private var source: DispatchSourceProcess?
    private var onExit: (@MainActor () -> Void)?

    init(pid: Int32, onExit: @escaping @MainActor () -> Void) {
        self.pid = pid
        self.onExit = onExit
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        source = src
        src.resume()
        // Process may already be gone before the source was armed.
        if kill(pid, 0) != 0 && errno == ESRCH { fire() }
    }

    var isAlive: Bool { source != nil && kill(pid, 0) == 0 }

    private func fire() {
        source?.cancel(); source = nil
        let cb = onExit; onExit = nil
        cb?()
    }

    func cancel() { source?.cancel(); source = nil; onExit = nil }
}
