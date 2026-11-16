import SwiftUI
import UniformTypeIdentifiers
import CMACore

enum SourceChoice: Hashable, CaseIterable {
    case moveRegular, empty, restore, later

    var title: String {
        switch self {
        case .moveRegular: "Move regular Claude into a profile"
        case .empty: "Start empty"
        case .restore: "Restore a backup"
        case .later: "Not now"
        }
    }

    var detail: String {
        switch self {
        case .moveRegular: "Your current sign-in, settings, MCP servers and sessions become this profile — no new sign-in. Regular Claude starts fresh afterwards."
        case .empty: "A clean Claude. Sign in with a different account when it opens."
        case .restore: "Pick a .zip saved with Export Backup."
        case .later: "Skip for now. You can add profiles any time."
        }
    }
}

/// Radio-style list of profile sources, shared by the New Profile sheet and onboarding.
struct SourceChoiceList: View {
    @Binding var selection: SourceChoice
    var choices: [SourceChoice]
    var recommended: SourceChoice?

    var body: some View {
        Picker("Start from", selection: $selection) {
            ForEach(choices, id: \.self) { choice in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(choice.title)
                        if choice == recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: .capsule)
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(choice.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
                .tag(choice)
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }
}

struct NewProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var choice: SourceChoice
    @State private var name = ""
    @State private var color: ProfileColor = .blue
    @State private var backupURL: URL?
    @State private var choosingBackup = false
    @State private var creating = false

    init(preset: NewProfileSource?) {
        switch preset {
        case .moveRegular: _choice = State(initialValue: .moveRegular)
        case .restore(let url): _choice = State(initialValue: .restore); _backupURL = State(initialValue: url)
        default: _choice = State(initialValue: .empty)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SourceChoiceList(selection: $choice, choices: [.moveRegular, .empty, .restore],
                                     recommended: model.profiles.isEmpty && model.services.regularClaudeHasData() ? .moveRegular : nil)
                } header: {
                    Text("New Profile").font(.title2.bold()).foregroundStyle(.primary)
                }

                if choice == .restore {
                    Section {
                        LabeledContent {
                            Button(backupURL == nil ? "Choose Backup…" : "Change…") { choosingBackup = true }
                        } label: {
                            Text("Backup file")
                            Text(backupURL?.lastPathComponent ?? "None chosen")
                        }
                    }
                }

                ProfileIdentityFields(name: $name, color: $color, nameError: nameError)

                if choice == .moveRegular && model.isRunning(.regular) {
                    Section {
                        NoticeRow(style: .warning, title: "Regular Claude is running",
                                  message: "It will be quit before its data moves. Unsaved drafts in Claude may be lost.")
                    }
                }
            }
            .formStyle(.grouped)

            SheetButtons {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle) { create() }
                    .primaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .frame(width: 520)
        .frame(minHeight: 480)
        .fileImporter(isPresented: $choosingBackup, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result {
                backupURL = url
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " Backup", with: "") }
            }
        }
        .onAppear {
            if let unused = ProfileColor.allCases.first(where: { c in !model.profiles.contains { $0.color == c } }) { color = unused }
        }
    }

    private var nameError: String? {
        name.isEmpty ? nil : model.services.validateName(name, excluding: nil)
    }

    private var canCreate: Bool {
        guard !creating, !name.trimmingCharacters(in: .whitespaces).isEmpty, nameError == nil else { return false }
        if choice == .restore { return backupURL != nil }
        return true
    }

    private var primaryTitle: String {
        if creating { return "Working…" }
        switch choice {
        case .moveRegular: return model.isRunning(.regular) ? "Quit Claude and Move" : "Move"
        case .restore: return "Restore"
        default: return "Create"
        }
    }

    private func create() {
        let source: NewProfileSource
        switch choice {
        case .moveRegular: source = .moveRegular
        case .restore:
            guard let backupURL else { return }
            source = .restore(backupURL)
        default: source = .empty
        }
        creating = true
        model.createProfile(name: name, color: color, source: source) { ok in
            creating = false
            if ok { dismiss() }
        }
    }
}

/// Name + color fields shared by the New, Edit and onboarding flows.
struct ProfileIdentityFields: View {
    @Binding var name: String
    @Binding var color: ProfileColor
    var nameError: String?
    var colorLocked = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                ProfileBadge(letter: name.first.map { String($0).uppercased() } ?? "?", color: color, size: 40)
                TextField("Name", text: $name, prompt: Text("e.g. Work"))
            }
            if let nameError {
                Text(nameError).font(.caption).foregroundStyle(.red)
            }
            LabeledContent {
                ColorSwatchPicker(selection: $color, disabled: colorLocked)
            } label: {
                Text("Color")
                if colorLocked { Text("Quit the profile to change its color.") }
            }
        } header: {
            Text("Profile")
        }
    }
}

/// Bottom action bar for sheets: glass buttons trailing.
struct SheetButtons<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) { content }
            }
        }
        .controlSize(.large)
        .padding(16)
    }
}
