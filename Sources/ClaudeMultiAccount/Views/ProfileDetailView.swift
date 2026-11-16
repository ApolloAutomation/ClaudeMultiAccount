import SwiftUI
import AppKit
import CMACore

struct ProfileDetailView: View {
    @Environment(AppModel.self) private var model
    let profileID: UUID

    @State private var confirmDelete = false
    @State private var showSyncHelp = false

    var body: some View {
        if let profile = model.profile(profileID) {
            content(profile)
        }
    }

    private func content(_ profile: Profile) -> some View {
        let target = ClaudeTarget.profile(profile.id)
        let state = model.runState(target)
        return Form {
            header(profile, state: state)
            notices(profile)
            PlanUsageSection(usage: model.usage[target] ?? .unknown, whoRecords: profile.name)
            switching(profile)
            tellingApart(profile, running: state.isRunning)
            bringOver(profile, running: state.isRunning)
            terminal(profile)
            backup(profile, running: state.isRunning)
            profileApp(profile, running: state.isRunning)
        }
        .formStyle(.grouped)
        .navigationTitle(profile.name)
        .navigationSubtitle(model.statusLine(target))
        .toolbar { toolbar(profile, state: state) }
        .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) { model.delete(profile) }
        } message: {
            Text("The profile app, its shortcuts and terminal command are removed. Its data folder goes to the Trash, so you can still recover it.")
        }
        .task(id: profile.id) { await model.refreshStorage(target) }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ profile: Profile, state: RunState) -> some ToolbarContent {
        let target = ClaudeTarget.profile(profile.id)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Edit…") { model.activeSheet = .edit(profile.id) }
                .help("Rename or restyle this profile")
            if state.isRunning {
                Button("Quit") { model.quit(target) }
                    .disabled(model.isBusy("quit-\(target)"))
            }
            Button(state.isRunning ? "Bring to Front" : "Open") { model.openOrFront(target) }
                .buttonStyle(.glassProminent)
                .disabled(model.isBusy("open-\(target)"))
            Menu {
                Button("Rebuild App…") { model.rebuild(profile) }.disabled(state.isRunning)
                Button("Show App in Finder") { model.services.revealInFinder(model.services.appURL(for: profile)) }
                Button("Open Data Folder") { model.services.openFolder(model.services.paths.dataDir(for: profile.id)) }
                Divider()
                Button("Delete Profile…", role: .destructive) { confirmDelete = true }.disabled(state.isRunning)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
        }
    }

    // MARK: Sections

    private func header(_ profile: Profile, state: RunState) -> some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                ProfileBadge(letter: profile.initial, color: profile.color, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.largeTitle.bold()).lineLimit(1)
                    HStack(spacing: 8) {
                        StatusCapsule(state: state)
                        Text(metaLine(profile, state: state))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }

    private func metaLine(_ profile: Profile, state: RunState) -> String {
        var parts = [profile.color.displayName]
        if !state.isRunning { parts.append(model.statusLine(.profile(profile.id))) }
        parts.append(model.appName(profile))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func notices(_ profile: Profile) -> some View {
        let shared = model.sharedAccountNames(for: profile)
        let signedIn = model.services.accountID(for: .profile(profile.id)) != nil
        if !signedIn || !shared.isEmpty {
            Section {
                if !signedIn {
                    NoticeRow(style: .info, title: "Tip: sign in using a private browser window",
                              message: "When Claude opens a browser to sign in, paste the link into a private window so your browser doesn't reuse an account that's already signed in.")
                }
                if !shared.isEmpty {
                    NoticeRow(style: .warning, title: "Same account as \(ListFormatter.localizedString(byJoining: shared))",
                              message: "Profiles are most useful with different accounts. Sign out here and sign in with another account if this wasn't intended.")
                }
            }
        }
    }

    private func switching(_ profile: Profile) -> some View {
        let inDock = model.services.isInDock(profile)
        let onDesktop = model.services.isOnDesktop(profile)
        return Section("Switching") {
            LabeledContent {
                ShortcutRecorder(shortcut: profile.hotKey) { model.setHotKey($0, for: profile) }
            } label: {
                Text("Keyboard shortcut")
                Text("Opens \(profile.name), or brings it forward, from any app.")
            }
            LabeledContent {
                Button(inDock ? "Remove from Dock" : "Add to Dock") { model.setInDock(!inDock, profile) }
                    .disabled(model.isBusy("dock-\(profile.id)"))
            } label: {
                Text("Dock")
                Text(inDock ? "In the Dock" : "Not in the Dock")
            }
            LabeledContent {
                Button(onDesktop ? "Remove from Desktop" : "Add to Desktop") { model.setDesktop(!onDesktop, profile) }
                    .disabled(model.isBusy("desktop-\(profile.id)"))
            } label: {
                Text("Desktop shortcut")
                Text(onDesktop ? "On the desktop" : "Not on the desktop")
            }
        }
    }

    private func tellingApart(_ profile: Profile, running: Bool) -> some View {
        Section {
            LabeledContent {
                ColorSwatchPicker(selection: binding(profile, \.color), disabled: running)
            } label: {
                Text("Color")
                Text(running ? "Quit \(profile.name) to change its color." : profile.color.displayName)
            }
            Toggle(isOn: binding(profile, \.showBorder)) {
                Text("Colored border around Claude windows")
                Text("Outlines \(profile.name)'s windows in \(profile.color.displayName.lowercased()), including in full screen.")
            }
            Picker("Border thickness", selection: binding(profile, \.borderWidth)) {
                ForEach(BorderWidth.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!profile.showBorder)
        } header: {
            Text("Telling It Apart")
        } footer: {
            if running {
                Text("Border changes show up the next time \(profile.name) opens.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bringOver(_ profile: Profile, running: Bool) -> some View {
        let regularRunning = model.isRunning(.regular)
        let signedIn = model.services.accountID(for: .profile(profile.id)) != nil
        return Section("Bring Over From Regular Claude") {
            if running {
                HStack {
                    NoticeRow(style: .warning, title: "Quit \(profile.name) first",
                              message: "Claude keeps these files open while it runs, so copying now could lose changes.")
                    Spacer()
                    Button("Quit \(profile.name)") { model.quit(.profile(profile.id)) }
                        .buttonStyle(.glass)
                }
            }
            LabeledContent {
                Button("Import…") { model.activeSheet = .importSettings(profile.id) }
                    .disabled(running)
            } label: {
                Text("MCP servers and settings")
                Text("Adds MCP servers, extensions and developer settings that \(profile.name) doesn't have yet. Nothing it already has is changed.")
            }
            LabeledContent {
                HStack {
                    Button {
                        showSyncHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("How syncing works")
                    .popover(isPresented: $showSyncHelp, arrowEdge: .bottom) { SyncHelp() }
                    Button("Sync…") { model.activeSheet = .sync(profile.id) }
                        .disabled(running || regularRunning || !signedIn)
                }
            } label: {
                Text("Claude Code sessions")
                Text("Copies sessions each side is missing and keeps whichever copy got further. Nothing is deleted. Runs only when you ask.")
                if !signedIn {
                    Text("Sign in to \(profile.name) before syncing.").foregroundStyle(.orange)
                } else if regularRunning {
                    Text("Quit regular Claude to sync.").foregroundStyle(.orange)
                }
            }
        }
    }

    private func terminal(_ profile: Profile) -> some View {
        let command = model.services.terminalCommandName(for: profile)
        return Section("Terminal Command") {
            Toggle(isOn: Binding(get: { profile.terminalCommand }, set: { model.setTerminal($0, profile) })) {
                Text("Use Claude Code as \(profile.name)")
                Text("Installs a `\(command)` command that starts Claude Code in Terminal with \(profile.name)'s own sign-in.")
            }
            .disabled(model.isBusy("terminal-\(profile.id)"))
        }
    }

    private func backup(_ profile: Profile, running: Bool) -> some View {
        let target = ClaudeTarget.profile(profile.id)
        let info = model.storage[target] ?? .unknown
        return Section {
            LabeledContent("Data folder", value: info.dataBytes?.byteString ?? "Calculating…")
            LabeledContent("Cache", value: info.cacheBytes?.byteString ?? "Calculating…")
            HStack {
                Button("Export Backup…") { model.exportBackup(profile) }
                    .disabled(running || model.isBusy("backup-\(profile.id)"))
                Button("Clear Cache") { model.clearCache(target) }
                    .disabled(running || model.isBusy("cache-\(target)"))
                Spacer()
            }
        } header: {
            Text("Backup & Storage")
        } footer: {
            Text(running ? "Quit \(profile.name) to export a backup or clear its cache."
                         : "A backup holds this profile's settings and data. Restoring on another Mac needs a new sign-in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func profileApp(_ profile: Profile, running: Bool) -> some View {
        let appURL = model.services.appURL(for: profile)
        let path = model.abbreviated(appURL)
        return Section {
            LabeledContent("Location") {
                Text(path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Button("Show in Finder") { model.services.revealInFinder(appURL) }
                Button("Open Data Folder") { model.services.openFolder(model.services.paths.dataDir(for: profile.id)) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appURL.path(percentEncoded: false), forType: .string)
                }
                Spacer()
            }
            HStack {
                Button("Rebuild App…") { model.rebuild(profile) }
                    .disabled(running || model.isBusy("rebuild-\(profile.id)"))
                Button("Delete Profile…", role: .destructive) { confirmDelete = true }
                    .disabled(running)
                Spacer()
            }
        } header: {
            Text("Profile App")
        } footer: {
            if running {
                Text("Quit \(profile.name) to rebuild or delete it.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binding<Value>(_ profile: Profile, _ keyPath: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        Binding {
            model.profile(profile.id)?[keyPath: keyPath] ?? profile[keyPath: keyPath]
        } set: { newValue in
            guard var current = model.profile(profile.id) else { return }
            current[keyPath: keyPath] = newValue
            model.update(current)
        }
    }
}

struct SyncHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How session sync works").font(.headline)
            Label("Each session is compared by how far it got: turns first, then last activity.", systemImage: "arrow.left.arrow.right")
            Label("Same account on both sides: missing sessions are copied both ways.", systemImage: "person")
            Label("Different accounts: you choose one direction.", systemImage: "person.2")
            Label("Replaced files are backed up first. Nothing is ever deleted.", systemImage: "externaldrive.badge.checkmark")
            Label("Scheduled tasks and sessions you deleted are left alone.", systemImage: "calendar.badge.exclamationmark")
        }
        .labelStyle(.titleAndIcon)
        .padding()
        .frame(width: 380)
    }
}
