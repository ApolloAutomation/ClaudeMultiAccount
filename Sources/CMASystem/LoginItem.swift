import Foundation
import ServiceManagement

/// Launch at login for the manager app (`SMAppService.mainApp`).
public enum LoginItem {
    public enum State: Sendable, Equatable { case enabled, disabled, requiresApproval, unavailable }

    @MainActor public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    @MainActor public static func setEnabled(_ on: Bool) throws {
        if on {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    @MainActor public static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
