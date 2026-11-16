import SwiftUI
import AppKit
import CMACore

/// Menu bar panel (`.window` style). Open profiles come first (front one first), each row shows
/// status and plan usage. Click brings forward or opens; ⌥-click (or the × button) quits.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppPaths.appName)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            VStack(spacing: 2) {
                if model.profiles.isEmpty {
                    Text("No profiles yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                ForEach(model.menuOrderedProfiles) { profile in
                    TargetRow(target: .profile(profile.id), title: profile.name) {
                        ProfileBadge(letter: profile.initial, color: profile.color, size: 32)
                    } onSelect: { dismiss() }
                }
            }

            Divider().padding(.vertical, 6).padding(.horizontal, 12)

            TargetRow(target: .regular, title: "Regular Claude") {
                OutlineBadge(text: "R", size: 32)
            } onSelect: { dismiss() }

            Divider().padding(.vertical, 6).padding(.horizontal, 12)

            VStack(spacing: 2) {
                ActionRow(title: "Open \(AppPaths.appName)", shortcut: "⌘O") { showMain() }
                    .keyboardShortcut("o")
                ActionRow(title: "New Profile…", shortcut: "⌘N") {
                    showMain()
                    model.activeSheet = .newProfile(nil)
                }
                .keyboardShortcut("n")
                ActionRow(title: "Settings…", shortcut: "⌘,") {
                    dismiss()
                    NSApp.activate()
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",")
                ActionRow(title: "Quit \(AppPaths.appName)", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }

            Text("⌥-click a running profile to quit it")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 6)
        .frame(width: 340)
    }

    private func showMain() {
        dismiss()
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}

/// One profile or regular-Claude row: badge, name, "status · 5h · week", quit button on hover.
private struct TargetRow<Badge: View>: View {
    @Environment(AppModel.self) private var model
    var target: ClaudeTarget
    var title: String
    @ViewBuilder var badge: Badge
    var onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        let state = model.runState(target)
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.isRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(subtitle(state))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if state.isRunning && hovering {
                Button {
                    model.quit(target)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit \(title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowFill(state))
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) {
                if state.isRunning { model.quit(target) }
                return
            }
            onSelect()
            model.openOrFront(target)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func rowFill(_ state: RunState) -> AnyShapeStyle {
        if hovering { return AnyShapeStyle(.quaternary) }
        if state == .runningInFront { return AnyShapeStyle(Color.accentColor.opacity(0.12)) }
        return AnyShapeStyle(.clear)
    }

    private func subtitle(_ state: RunState) -> String {
        var parts: [String] = [state.isRunning ? (state == .runningInFront ? "In front" : "Running") : model.statusLine(target)]
        if let usage = usageSummary(model.usage[target]) { parts.append(usage) }
        return parts.joined(separator: " · ")
    }
}

/// Plain menu-style action row with a trailing shortcut hint.
private struct ActionRow: View {
    var title: String
    var shortcut: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.secondary)
            }
            .font(.body)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
