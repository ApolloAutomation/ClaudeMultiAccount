import SwiftUI
import CMACore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.activeSheet = .newProfile(nil)
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .help("Create a new profile")
            }
        }
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .newProfile(let preset): NewProfileSheet(preset: preset)
            case .edit(let id): EditProfileSheet(profileID: id)
            case .sync(let id): SyncSheet(profileID: id)
            case .importSettings(let id): ImportSheet(profileID: id)
            case .onboarding: OnboardingView()
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .frame(minWidth: 820, minHeight: 560)
        .opensLinkPicker()
        .tracksActivationPolicy()
        .task { model.start() }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .profile(let id):
            if model.profile(id) != nil {
                ProfileDetailView(profileID: id).id(id)
            } else {
                emptyState
            }
        case .regular: RegularClaudeView()
        case .memory: MemoryView()
        case nil: emptyState
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Profile Selected", systemImage: "person.2.crop.square.stack")
        } description: {
            Text("Each profile is its own Claude app with a separate sign-in, chats and settings.")
        } actions: {
            Button("New Profile…") { model.activeSheet = .newProfile(nil) }
                .buttonStyle(.glassProminent)
        }
    }
}

/// Opens the link picker window whenever a link is waiting for a choice.
struct LinkPickerOpener: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: model.pendingLinks.first?.id) { _, id in
            if id != nil { openWindow(id: WindowID.linkPicker) }
        }
    }
}

extension View {
    func opensLinkPicker() -> some View { modifier(LinkPickerOpener()) }
}
