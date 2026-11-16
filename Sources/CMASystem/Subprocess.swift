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
public enum Subprocess {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var timedOut = false
    }
    private final class ProcessRef: @unchecked Sendable {
        let process: Process
        init(_ p: Process) { process = p }
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
        let errBox = Box()
        let group = DispatchGroup()
        group.enter()
        let errHandle = err.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            let d = errHandle.readDataToEndOfFile()
            errBox.lock.withLock { errBox.data = d }
            group.leave()
        }
        let state = Box()
        var timer: DispatchWorkItem?
        if let timeout {
            let ref = ProcessRef(p)
            let item = DispatchWorkItem {
                if ref.process.isRunning {
                    state.lock.withLock { state.timedOut = true }
                    ref.process.terminate()
                }
            }
            timer = item
            let secs = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + secs, execute: item)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        timer?.cancel()
        if state.lock.withLock({ state.timedOut }) { throw SubprocessError.timedOut(path: executable.path) }
        return SubprocessResult(status: p.terminationStatus, stdout: outData, stderr: errBox.lock.withLock { errBox.data })
    }

    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                           currentDirectory: URL? = nil, timeout: Duration? = nil) async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try runSync(executable, arguments, environment: environment,
                                                       currentDirectory: currentDirectory, timeout: timeout) })
            }
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
