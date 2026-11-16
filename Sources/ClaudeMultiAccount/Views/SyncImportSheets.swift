import SwiftUI
import CMACore

struct SyncSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID

    @State private var direction: SyncDirection = .both
    @State private var preview: SyncPreview?
    @State private var loadError: String?
    @State private var running = false

    var body: some View {
        let name = model.profile(profileID)?.name ?? "Profile"
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Sync Claude Code Sessions").font(.title2.bold())
                    Text("Regular Claude ⇄ \(name)").foregroundStyle(.secondary)
                }

                if model.isRunning(.regular) || model.isRunning(.profile(profileID)) {
                    Section {
                        NoticeRow(style: .warning, title: "Quit both apps first",
                                  message: "Regular Claude and \(name) must be closed so no session file changes mid-copy.")
                    }
                }

                if let preview, !preview.sameAccount {
                    Section {
                        Picker("Direction", selection: $direction) {
                            Text("Regular Claude → \(name)").tag(SyncDirection.regularToProfile)
                            Text("\(name) → Regular Claude").tag(SyncDirection.profileToRegular)
                        }
                        .pickerStyle(.radioGroup)
                    } header: {
                        Text("Different accounts")
                    } footer: {
                        Text("These are signed in to different accounts, so sessions copy one way and are filed under the destination's account.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    if let loadError {
                        NoticeRow(style: .critical, title: "Can't sync right now", message: loadError)
                    } else if let preview {
                        if preview.items.isEmpty {
                            Text("Everything is already in sync.").foregroundStyle(.secondary)
                        }
                        ForEach(preview.items) { item in
                            HStack {
                                Image(systemName: item.action.symbol).foregroundStyle(.tint).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).lineLimit(1)
                                    Text([item.cwd, item.lastActivity?.formatted(.relative(presentation: .named))]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.action.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Comparing sessions…").foregroundStyle(.secondary) }
                    }
                } header: {
                    Text("Changes")
                } footer: {
                    if let preview {
                        Text("\(preview.items.count) to copy · \(preview.unchanged) unchanged. Files that get replaced are backed up first; nothing is deleted.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            SheetButtons {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(running ? "Syncing…" : "Sync \(preview?.items.count ?? 0) Sessions") { execute() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || preview?.items.isEmpty != false)
            }
        }
        .frame(width: 560, height: 520)
        .task(id: direction) { await load() }
    }

    private func load() async {
        guard let profile = model.profile(profileID) else { return }
        do {
            let result = try await model.services.syncPreview(profile: profile, direction: direction)
            preview = result
            loadError = nil
            if !result.sameAccount && direction == .both { direction = result.direction }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func execute() {
        guard let profile = model.profile(profileID), let preview else { return }
        running = true
        Task {
            defer { running = false }
            do {
                let count = try await model.services.executeSync(preview, profile: profile)
                dismiss()
                model.alert = AppAlert(title: "Sessions synced", message: "\(count) session\(count == 1 ? "" : "s") copied.")
            } catch {
                model.show(error, title: "Sync didn't finish")
            }
        }
    }
}

struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID

    @State private var preview: ImportPreview?
    @State private var loadError: String?
    @State private var running = false

    var body: some View {
        let name = model.profile(profileID)?.name ?? "Profile"
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Import From Regular Claude").font(.title2.bold())
                    Text("Only things \(name) doesn't have yet are added. Existing settings stay as they are.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    if let loadError {
                        NoticeRow(style: .critical, title: "Can't import right now", message: loadError)
                    } else if let preview {
                        if preview.items.isEmpty {
                            Text("\(name) already has everything.").foregroundStyle(.secondary)
                        }
                        ForEach(preview.items) { item in
                            Label {
                                LabeledContent(item.name, value: item.kind.rawValue)
                            } icon: {
                                Image(systemName: item.kind.symbol).foregroundStyle(.tint)
                            }
                        }
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Looking for missing items…").foregroundStyle(.secondary) }
                    }
                } header: {
                    Text("Will be added")
                } footer: {
                    if let preview, preview.alreadyPresent > 0 {
                        Text("\(preview.alreadyPresent) item\(preview.alreadyPresent == 1 ? "" : "s") already present will be left alone. Sign-in and chats are never copied.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            SheetButtons {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(running ? "Importing…" : "Import") { execute() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || preview?.items.isEmpty != false)
            }
        }
        .frame(width: 520, height: 460)
        .task { await load() }
    }

    private func load() async {
        guard let profile = model.profile(profileID) else { return }
        do {
            preview = try await model.services.importPreview(profile: profile)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func execute() {
        guard let profile = model.profile(profileID), let preview else { return }
        running = true
        Task {
            defer { running = false }
            do {
                let count = try await model.services.executeImport(preview, profile: profile)
                dismiss()
                model.alert = AppAlert(title: "Import finished", message: "\(count) item\(count == 1 ? "" : "s") added to \(profile.name).")
            } catch {
                model.show(error, title: "Import didn't finish")
            }
        }
    }
}
