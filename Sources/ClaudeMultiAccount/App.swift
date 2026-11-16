import SwiftUI
import AppKit
import CMACore
import CMASystem
import Carbon

enum WindowID {
    static let main = "main"
    static let linkPicker = "link-picker"
}

/// Chooses the services backing the UI: live by default, sample data with `--mock` / `--demo-link`.
@MainActor
enum ServicesFactory {
    static func make() -> any ProfileServices {
        let args = CommandLine.arguments
        if args.contains("--mock") || args.contains("--demo-link") {
            return MockProfileServices(emitDemoLink: args.contains("--demo-link"))
        }
        return LiveProfileServices()
    }
}

/// Command-line modes that run without any UI (used by scripts/build-app.sh).
enum CommandLineMode {
    static let renderAppIconFlag = "--render-app-icon"

    /// `--render-app-icon <path.icns>`: writes the manager's icon and exits.
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: renderAppIconFlag) else { return }
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("usage: \(renderAppIconFlag) <output.icns>\n".utf8))
            exit(64)
        }
        do {
            try IconRenderer.writeICNS(letter: "C", color: .orange, to: URL(filePath: args[i + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("icon render failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // claude:// links (link routing). Installed before launch finishes so the launching link isn't lost.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement apps start as accessories; bring the main window forward on a normal launch.
        guard !CommandLine.arguments.contains("--background") else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Fallback path if AppKit/SwiftUI delivers URLs through the delegate instead.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(LinkInbox.shared.receive) }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let url = URLForwarder.url(fromGetURLEvent: event) else { return }
        MainActor.assumeIsolated { LinkInbox.shared.receive(url) }
    }
}

@main
struct ClaudeMultiAccountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        CommandLineMode.runIfRequested()
        _model = State(initialValue: AppModel(services: ServicesFactory.make()))
    }

    var body: some Scene {
        Window(AppPaths.appName, id: WindowID.main) {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 1000, height: 760)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Profile…") { model.activeSheet = .newProfile(nil) }
                    .keyboardShortcut("n")
            }
        }

        Window("Open Link", id: WindowID.linkPicker) {
            LinkPickerView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarMenu()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.menu)
    }
}
