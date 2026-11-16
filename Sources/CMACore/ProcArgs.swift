import Darwin
import Foundation

/// Parser for the `KERN_PROCARGS2` sysctl blob: int32 argc, exec path, NUL padding, argv[argc], env…
public struct ProcArgs: Sendable, Equatable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String]

    public init(executablePath: String, arguments: [String], environment: [String] = []) {
        self.executablePath = executablePath; self.arguments = arguments; self.environment = environment
    }

    public static func parse(_ bytes: [UInt8]) -> ProcArgs? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(Int32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc >= 0, argc < 1_000_000 else { return nil }
        var i = 4
        func cString() -> String? {
            guard i < bytes.count else { return nil }
            let start = i
            while i < bytes.count && bytes[i] != 0 { i += 1 }
            let s = String(decoding: bytes[start..<i], as: UTF8.self)
            return s
        }
        guard let exec = cString() else { return nil }
        while i < bytes.count && bytes[i] == 0 { i += 1 }
        var args: [String] = []
        for _ in 0..<argc {
            guard i < bytes.count, let a = cString() else { return nil }
            args.append(a)
            i += 1
        }
        var env: [String] = []
        while i < bytes.count {
            if bytes[i] == 0 { i += 1; continue }
            guard let e = cString() else { break }
            env.append(e)
            i += 1
        }
        return ProcArgs(executablePath: exec, arguments: args, environment: env)
    }

    public static func parse(_ data: Data) -> ProcArgs? { parse([UInt8](data)) }

    /// Reads a process's argument blob via sysctl (read-only). nil if not permitted or gone.
    public static func fetch(pid: Int32) -> ProcArgs? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buf.prefix(size)))
    }

    public static let userDataDirFlag = "--user-data-dir"

    /// Accepts `--user-data-dir=X` and `--user-data-dir X` (argv[0] ignored). Empty value → nil.
    public static func userDataDir(from arguments: [String]) -> String? {
        var it = arguments.dropFirst().makeIterator()
        while let a = it.next() {
            if a.hasPrefix(userDataDirFlag + "=") {
                let v = String(a.dropFirst(userDataDirFlag.count + 1))
                return v.isEmpty ? nil : v
            }
            if a == userDataDirFlag {
                guard let v = it.next(), !v.isEmpty, !v.hasPrefix("--") else { return nil }
                return v
            }
        }
        return nil
    }

    public var userDataDir: String? { Self.userDataDir(from: arguments) }

    /// Standardized, symlink-resolved, trailing slash removed, lowercased (case-insensitive compare).
    public static func normalize(_ path: String) -> String {
        var p = URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.lowercased()
    }

    public static func sameDir(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }
}
