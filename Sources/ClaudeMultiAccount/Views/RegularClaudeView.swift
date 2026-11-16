import SwiftUI
import CMACore

struct RegularClaudeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let target = ClaudeTarget.regular
        let state = model.runState(target)
        let desktop = model.services.claudeDesktop()
        let info = model.storage[target] ?? .unknown
        Form {
            Section {
                HStack(spacing: 16) {
                    OutlineBadge(text: "R", size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Regular Claude").font(.largeTitle.bold())
                        HStack(spacing: 8) {
                            StatusCapsule(state: state)
                            Text("Claude without a profile, using its usual data folder")
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }

            Section("Claude Desktop") {
                if let desktop {
                    LabeledContent("Installed at") {
                        Text(model.abbreviated(desktop.appURL)).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Version", value: desktop.version)
                } else {
                    NoticeRow(style: .critical, title: "Claude Desktop isn't installed",
                              message: "Download it from claude.ai/download, then come back here.")
                }
            }

            PlanUsageSection(usage: model.usage[target] ?? .unknown, whoRecords: "regular Claude")

            Section {
                LabeledContent {
                    Button("Move into a Profile…") { model.activeSheet = .newProfile(.moveRegular) }
                        .disabled(!model.services.regularClaudeHasData())
                } label: {
                    Text("Turn it into a profile")
                    Text("Moves the current sign-in, settings, MCP servers and sessions into a new profile. Regular Claude then starts fresh.")
                }
            } header: {
                Text("Make It a Profile")
            }

            Section {
                LabeledContent("Data folder", value: info.dataBytes?.byteString ?? "Calculating…")
                LabeledContent("Cache", value: info.cacheBytes?.byteString ?? "Calculating…")
                HStack {
                    Button("Open Data Folder") { model.services.openFolder(model.services.paths.regularClaudeDir) }
                    Spacer()
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Regular Claude's folder is never modified here. Claude manages its own cache.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Regular Claude")
        .navigationSubtitle(model.statusLine(target))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if state.isRunning {
                    Button("Quit") { model.quit(target) }
                }
                Button(state.isRunning ? "Bring to Front" : "Open") { model.openOrFront(target) }
                    .buttonStyle(.glassProminent)
                    .disabled(desktop == nil)
            }
        }
        .task { await model.refreshStorage(target) }
    }
}
