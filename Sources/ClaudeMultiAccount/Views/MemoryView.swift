import SwiftUI

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var pendingCopy: PendingCopy?
    @State private var confirmRules = false
    @State private var working = false

    struct PendingCopy: Identifiable {
        let id = UUID()
        var notes: [MemoryNoteInfo]
        var project: MemoryProjectInfo
        var conflicts: [String]
    }

    var body: some View {
        Group {
            if let memory = model.memory {
                list(memory)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Memory")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .task { await model.loadMemory() }
        .confirmationDialog(conflictTitle, isPresented: Binding(get: { pendingCopy != nil }, set: { if !$0 { pendingCopy = nil } }),
                            titleVisibility: .visible, presenting: pendingCopy) { pending in
            Button("Replace (keeps a backup)") { runCopy(pending, .replace) }
            Button("Keep Both") { runCopy(pending, .keepBoth) }
            Button("Skip Those Notes") { runCopy(pending, .skip) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.conflicts.joined(separator: ", "))
        }
        .confirmationDialog("Add \(selectedNotes.count) note\(selectedNotes.count == 1 ? "" : "s") to general rules?",
                            isPresented: $confirmRules, titleVisibility: .visible) {
            Button("Add to General Rules") { runMakeRules() }
        } message: {
            Text("They're appended to ~/.claude/CLAUDE.md under a shared heading, so every project sees them. A backup is saved first, and notes already added are skipped.")
        }
    }

    private func list(_ memory: MemoryOverview) -> some View {
        List(selection: $selection) {
            Section {
                HStack(spacing: 12) {
                    OutlineBadge(symbol: "doc.text", size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("General rules").font(.headline)
                        Text("\(model.abbreviated(memory.generalRulesURL))\(memory.generalRulesLineCount.map { " · \($0) lines" } ?? " · not created yet")")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Claude Code reads this file in every project, for every profile.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show in Finder") { model.services.revealInFinder(memory.generalRulesURL) }
                    Button("Open in Editor") { model.services.openInEditor(memory.generalRulesURL) }
                }
                .padding(.vertical, 4)
                .selectionDisabled()
            } header: {
                Text("Every profile and the regular claude command share the same memory on this Mac.")
            }

            if memory.projects.isEmpty {
                Text("No project notes yet. Claude Code saves them as you work.")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            ForEach(memory.projects) { project in
                Section {
                    ForEach(project.notes) { note in
                        NoteRow(note: note)
                            .tag(note.id)
                            .contextMenu {
                                Button("Open in Editor") { model.services.openInEditor(note.url) }
                                Button("Show in Finder") { model.services.revealInFinder(note.url) }
                            }
                    }
                } header: {
                    HStack {
                        Text(project.name).font(.headline)
                        Text(project.displayPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(project.notes.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(model.memory?.projects ?? []) { project in
                    Button(project.name) { startCopy(to: project) }
                        .disabled(selectedNotes.allSatisfy { $0.projectID == project.id })
                }
            } label: {
                Label("Copy to Project", systemImage: "doc.on.doc")
            }
            .disabled(selectedNotes.isEmpty || working)
            .help("Copy the selected notes into another project's memory")

            Button {
                confirmRules = true
            } label: {
                Label("Make General Rules", systemImage: "text.badge.plus")
            }
            .disabled(selectedNotes.isEmpty || working)
            .help("Append the selected notes to ~/.claude/CLAUDE.md")
        }
    }

    private var subtitle: String {
        guard let memory = model.memory else { return "" }
        let base = "\(memory.noteCount) notes in \(memory.projects.count) projects"
        return selection.isEmpty ? base : "\(selection.count) selected · " + base
    }

    private var selectedNotes: [MemoryNoteInfo] {
        (model.memory?.projects ?? []).flatMap(\.notes).filter { selection.contains($0.id) }
    }

    private var conflictTitle: String {
        guard let pending = pendingCopy else { return "" }
        return "\(pending.conflicts.count) note\(pending.conflicts.count == 1 ? "" : "s") already exist in \(pending.project.name)"
    }

    private func startCopy(to project: MemoryProjectInfo) {
        let notes = selectedNotes
        let conflicts = model.services.memoryConflicts(notes: notes, project: project)
        let pending = PendingCopy(notes: notes, project: project, conflicts: conflicts)
        if conflicts.isEmpty { runCopy(pending, .skip) } else { pendingCopy = pending }
    }

    private func runCopy(_ pending: PendingCopy, _ policy: MemoryConflictPolicy) {
        pendingCopy = nil
        working = true
        Task {
            defer { working = false }
            do {
                let result = try await model.services.copyNotes(pending.notes, to: pending.project, policy: policy)
                model.alert = AppAlert(title: "Copied to \(pending.project.name)", message: result.summary + ".")
                selection.removeAll()
                await model.loadMemory()
            } catch {
                model.show(error, title: "Couldn't copy notes")
            }
        }
    }

    private func runMakeRules() {
        let notes = selectedNotes
        working = true
        Task {
            defer { working = false }
            do {
                let result = try await model.services.makeGeneralRules(notes)
                model.alert = AppAlert(title: "Added to general rules", message: result.summary + ".")
                selection.removeAll()
                await model.loadMemory()
            } catch {
                model.show(error, title: "Couldn't update general rules")
            }
        }
    }
}

private struct NoteRow: View {
    var note: MemoryNoteInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(note.title).fontWeight(.medium)
                if let type = note.type {
                    Text(type)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = note.summary {
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(note.fileName).font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
