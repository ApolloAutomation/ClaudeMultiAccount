import SwiftUI
import AppKit
import CMACore

/// Menu bar menu (`.menu` style). Open profiles come first; holding ⌥ while clicking quits instead of bringing forward.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }

    var body: some View {
        let ordered = model.menuOrderedProfiles
        let open = ordered.filter { model.isRunning(.profile($0.id)) }
        let closed = ordered.filter { !model.isRunning(.profile($0.id)) }

        if !open.isEmpty {
            Section("Open") {
                ForEach(open) { profile in
                    runningMenu(.profile(profile.id), title: profile.name)
                }
            }
        }
        if !closed.isEmpty {
            Section(open.isEmpty ? "Profiles" : "Not Open") {
                ForEach(closed) { profile in
                    Button(profile.name) { model.open(.profile(profile.id)) }
                }
            }
        }

        Section {
            if model.isRunning(.regular) {
                runningMenu(.regular, title: "Regular Claude")
            } else {
                Button("Regular Claude") { model.open(.regular) }
            }
        }

        Divider()
        Button("Open \(AppPaths.appName)…") { showMain() }
            .keyboardShortcut("0")
        Button("New Profile…") {
            showMain()
            model.activeSheet = .newProfile(nil)
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Text("Hold ⌥ and click a profile to quit it")
        Button("Quit \(AppPaths.appName)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func runningMenu(_ target: ClaudeTarget, title: String) -> some View {
        let front = model.runState(target) == .runningInFront
        return Menu {
            Button("Bring to Front") { optionHeld ? model.quit(target) : model.bringToFront(target) }
            Button("Quit") { model.quit(target) }
            if let usage = usageSummary(model.usage[target]) {
                Divider()
                Text(usage)
            }
        } label: {
            Text(front ? "\(title) — in front" : title)
        } primaryAction: {
            optionHeld ? model.quit(target) : model.bringToFront(target)
        }
    }

    private func showMain() {
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.settings.showLetterInMenuBar, let front = model.frontProfile {
                Text(front.initial).font(.system(size: 13, weight: .heavy, design: .rounded))
            } else {
                Image(systemName: "person.2.crop.square.stack.fill")
            }
        }
        .task { model.start() }
        .opensLinkPicker()
    }
}
