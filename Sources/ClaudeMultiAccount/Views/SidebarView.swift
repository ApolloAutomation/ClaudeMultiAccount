import SwiftUI
import CMACore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Profiles") {
                if model.profiles.isEmpty {
                    Text("No profiles yet")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else if model.filteredProfiles.isEmpty {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(model.filteredProfiles) { profile in
                    ProfileSidebarRow(profile: profile)
                        .tag(SidebarItem.profile(profile.id))
                        .contextMenu { ProfileContextMenu(profile: profile) }
                }
            }

            Section("On This Mac") {
                SidebarRow(title: "Regular Claude", subtitle: model.statusLine(.regular),
                           running: model.isRunning(.regular)) {
                    OutlineBadge(text: "R")
                }
                .tag(SidebarItem.regular)
            }

            Section("Claude Code") {
                SidebarRow(title: "Memory", subtitle: "Shared by every profile", running: nil) {
                    OutlineBadge(symbol: "brain")
                }
                .tag(SidebarItem.memory)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
    }
}

struct ProfileSidebarRow: View {
    @Environment(AppModel.self) private var model
    var profile: Profile

    var body: some View {
        SidebarRow(title: profile.name, subtitle: model.statusLine(.profile(profile.id)),
                   running: model.isRunning(.profile(profile.id))) {
            ProfileBadge(letter: profile.initial, color: profile.color)
        }
    }
}

struct SidebarRow<Badge: View>: View {
    var title: String
    var subtitle: String
    /// nil hides the status dot.
    var running: Bool?
    @ViewBuilder var badge: Badge

    var body: some View {
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                HStack(spacing: 4) {
                    if let running {
                        Circle().fill(running ? Color.green : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
                    }
                    Text(subtitle).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ProfileContextMenu: View {
    @Environment(AppModel.self) private var model
    var profile: Profile

    var body: some View {
        let target = ClaudeTarget.profile(profile.id)
        if model.isRunning(target) {
            Button("Bring to Front") { model.bringToFront(target) }
            Button("Quit") { model.quit(target) }
        } else {
            Button("Open") { model.open(target) }
        }
        Divider()
        Button("Edit…") { model.activeSheet = .edit(profile.id) }
        Button("Show App in Finder") { model.services.revealInFinder(model.services.appURL(for: profile)) }
    }
}
