import Foundation

public enum LinkDecision: Sendable, Equatable {
    /// Nothing running: open the link in regular Claude.
    case openRegular
    case forward(pid: Int32)
    /// Several running: show the picker.
    case pick(candidates: [ClaudeInstance], preselected: Int32?)
    case reject
}

public enum LinkRouting {
    public static let scheme = "claude"
    public static let maxLength = 8192

    public static func isValid(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme else { return false }
        let s = url.absoluteString
        if s.count > maxLength { return false }
        return !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == " " }
    }

    /// Foreign instances are never routing targets.
    public static func decide(url: URL, instances: [ClaudeInstance], lastActiveAt: [UUID: Date] = [:]) -> LinkDecision {
        guard isValid(url) else { return .reject }
        let targets = instances.filter { if case .foreign = $0.kind { return false } else { return true } }
        switch targets.count {
        case 0: return .openRegular
        case 1: return .forward(pid: targets[0].pid)
        default:
            func activity(_ i: ClaudeInstance) -> Date {
                if i.isFrontmost { return .distantFuture }
                if case .profile(let id) = i.kind, let d = lastActiveAt[id] { return d }
                return i.launchDate ?? .distantPast
            }
            let best = targets.max { activity($0) < activity($1) }
            return .pick(candidates: targets, preselected: best?.pid)
        }
    }
}
