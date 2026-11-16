import CMACore
import Foundation

/// Backing store for `persistent-apps`. The default talks to `com.apple.dock` via CFPreferences.
public protocol DockPreferencesStore: Sendable {
    /// nil when the value can't be read or isn't an array: callers must not write in that case.
    func persistentApps() -> [Any]?
    func setPersistentApps(_ apps: [Any]) throws
}

public enum DockEditorError: Error, Equatable { case syncFailed, readFailed }

public struct CFPreferencesDockStore: DockPreferencesStore {
    public static let domain = "com.apple.dock"
    public static let key = "persistent-apps"
    public init() {}

    public func persistentApps() -> [Any]? {
        CFPreferencesAppSynchronize(Self.domain as CFString)
        return CFPreferencesCopyAppValue(Self.key as CFString, Self.domain as CFString) as? [Any]
    }

    public func setPersistentApps(_ apps: [Any]) throws {
        CFPreferencesSetAppValue(Self.key as CFString, apps as CFArray, Self.domain as CFString)
        guard CFPreferencesAppSynchronize(Self.domain as CFString) else { throw DockEditorError.syncFailed }
    }
}

/// Adds/removes profile app tiles. Writes preferences only; the Dock reloads on `restartDock()` (explicit user action).
public struct DockEditor: DockEditing {
    public let store: any DockPreferencesStore
    public let killall: URL

    public init(store: any DockPreferencesStore = CFPreferencesDockStore(), killall: URL = URL(fileURLWithPath: "/usr/bin/killall")) {
        self.store = store; self.killall = killall
    }

    public func isInDock(bundleID: String) -> Bool { DockPlist.contains(store.persistentApps() ?? [], bundleID: bundleID) }

    /// Read-modify-write of the user's Dock. Refuses to write when the current list can't be read,
    /// so a failed read never replaces the pinned apps with just our tile.
    public func add(appURL: URL, label: String, bundleID: String) throws {
        guard let apps = store.persistentApps() else { throw DockEditorError.readFailed }
        try store.setPersistentApps(DockPlist.adding(apps, appURL: appURL, label: label, bundleID: bundleID))
    }

    public func remove(bundleID: String) throws {
        guard let apps = store.persistentApps() else { throw DockEditorError.readFailed }
        guard DockPlist.contains(apps, bundleID: bundleID) else { return }
        try store.setPersistentApps(DockPlist.removing(apps, bundleID: bundleID))
    }

    /// `killall Dock` so it rereads its preferences. Only call from an explicit user action.
    public func restartDock() async throws {
        try await Subprocess.checked(killall, ["Dock"])
    }
}
