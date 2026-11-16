import AppKit
import CMACore
import CMASystem

// Diagnostic: `ProfileAgent --scan` prints how running Claude main processes are classified (read-only).
if CommandLine.arguments.contains("--scan") {
    for i in ProcessScanner().claudeInstances() {
        let kind: String = switch i.kind {
        case .regular: "regular"
        case .profile(let id): "profile \(id.uuidString)"
        case .foreign(let dir): "foreign \(dir.isEmpty ? "(argv unreadable)" : dir)"
        }
        print("pid \(i.pid)\t\(kind)\tfront=\(i.isFrontmost)\tlaunched=\(i.launchDate.map { "\($0)" } ?? "?")\tdir=\(i.dataDir.path)")
    }
    if let c = ClaudeLocator().locate() { print("Claude.app: \(c.url.path) \(c.displayVersion)") } else { print("Claude.app: not found") }
    exit(0)
}

let app = NSApplication.shared
let agentDelegate = AgentDelegate()
app.delegate = agentDelegate
app.setActivationPolicy(.accessory)
app.run()
