import Foundation

public struct SubprocessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
}

public enum SubprocessError: Error, Equatable, CustomStringConvertible {
    case launchFailed(path: String, reason: String)
    case nonZeroExit(path: String, status: Int32, stderr: String)
    case timedOut(path: String)

    public var description: String {
        switch self {
        case .launchFailed(let p, let r): "Could not run \(p): \(r)"
        case .nonZeroExit(let p, let s, let e): "\(p) exited with status \(s): \(e)"
        case .timedOut(let p): "\(p) timed out"
        }
    }
}

/// Runs an executable with an argv array. Never goes through a shell.
///
/// Pipe reads and the exit wait run on dedicated threads, never on GCD's shared pool: blocking a pool thread
/// while waiting for other pool work deadlocks once the pool is saturated (seen on 3-core CI runners).
public enum Subprocess {
    /// Collects one pipe to EOF on its own thread.
    private final class PipeReader: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var data = Data()
        init(_ handle: FileHandle) {
            let t = Thread { [self] in
                data = handle.readDataToEndOfFile()
                done.signal()
            }
            t.name = "Subprocess.PipeReader"
            t.start()
        }
        /// Waits for EOF; returns nil if it did not arrive in time (e.g. a grandchild still holds the pipe).
        func result(timeout: DispatchTime = .distantFuture) -> Data? {
            done.wait(timeout: timeout) == .success ? data : nil
        }
    }

    /// Blocking run; use `run` from async code.
    public static func runSync(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                               currentDirectory: URL? = nil, timeout: Duration? = nil) throws -> SubprocessResult {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let environment { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            throw SubprocessError.launchFailed(path: executable.path, reason: error.localizedDescription)
        }
        let outReader = PipeReader(out.fileHandleForReading)
        let errReader = PipeReader(err.fileHandleForReading)

        var timedOut = false
        if let timeout {
            let secs = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            let deadline = Date(timeIntervalSinceNow: secs)
            while p.isRunning {
                if Date() >= deadline { timedOut = true; p.terminate(); break }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        p.waitUntilExit()
        if timedOut {
            // Don't hang on pipes a surviving grandchild may still hold open.
            _ = outReader.result(timeout: .now() + 2); _ = errReader.result(timeout: .now() + 2)
            throw SubprocessError.timedOut(path: executable.path)
        }
        let stdout = outReader.result() ?? Data()
        let stderr = errReader.result() ?? Data()
        return SubprocessResult(status: p.terminationStatus, stdout: stdout, stderr: stderr)
    }

    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                           currentDirectory: URL? = nil, timeout: Duration? = nil) async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { cont in
            let t = Thread {
                cont.resume(with: Result { try runSync(executable, arguments, environment: environment,
                                                       currentDirectory: currentDirectory, timeout: timeout) })
            }
            t.name = "Subprocess.run"
            t.start()
        }
    }

    /// Like `run`, but throws `.nonZeroExit` on failure.
    @discardableResult
    public static func checked(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                               currentDirectory: URL? = nil, timeout: Duration? = nil) async throws -> SubprocessResult {
        let r = try await run(executable, arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout)
        guard r.succeeded else {
            throw SubprocessError.nonZeroExit(path: executable.path, status: r.status, stderr: r.stderrString)
        }
        return r
    }

    @discardableResult
    public static func checkedSync(_ executable: URL, _ arguments: [String], currentDirectory: URL? = nil) throws -> SubprocessResult {
        let r = try runSync(executable, arguments, currentDirectory: currentDirectory)
        guard r.succeeded else {
            throw SubprocessError.nonZeroExit(path: executable.path, status: r.status, stderr: r.stderrString)
        }
        return r
    }
}
