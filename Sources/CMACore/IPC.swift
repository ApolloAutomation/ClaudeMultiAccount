import Foundation

/// Distributed notification names shared by the manager and profile agents. Hints only; process scans are the source of truth.
public enum IPC {
    public static let prefix = AppPaths.bundleID
    /// Posted by the manager after a profile's settings change. Object: profile UUID string.
    public static let profileChanged = Notification.Name("\(prefix).profileChanged")
    /// Posted by an agent when its Claude instance launched or quit. Object: profile UUID string.
    public static let agentStateChanged = Notification.Name("\(prefix).agentStateChanged")
    /// Posted by the manager to ask an agent to quit its Claude. Object: profile UUID string.
    public static let quitProfile = Notification.Name("\(prefix).quitProfile")
    /// Launch argument for a profile app to open a claude:// URL once Claude is up.
    public static let openURLArgument = "--open-url"
}
