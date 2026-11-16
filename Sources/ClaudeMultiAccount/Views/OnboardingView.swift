import SwiftUI
import CMACore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome, claudeDesktop, firstProfile, links
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .claudeDesktop: "Claude Desktop"
            case .firstProfile: "First Profile"
            case .links: "Links"
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var choice: SourceChoice = .empty
    @State private var name = ""
    @State private var color: ProfileColor = .blue
    @State private var backupURL: URL?
    @State private var choosingBackup = false
    @State private var creating = false
    @State private var routeLinks = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Step \(step.rawValue + 1) of \(Step.allCases.count) · \(step.title)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    content
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack {
                Button("Skip Setup") { finish() }
                    .buttonStyle(.borderless)
                Spacer()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if step != .welcome {
                            Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
                        }
                        Button(primaryTitle) { primary() }
                            .primaryAction()
                            .keyboardShortcut(.defaultAction)
                            .disabled(!primaryEnabled)
                    }
                }
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: 640, height: 560)
        .interactiveDismissDisabled()
        .fileImporter(isPresented: $choosingBackup, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result {
                backupURL = url
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            }
        }
        .onAppear {
            choice = model.services.regularClaudeHasData() ? .moveRegular : .empty
            name = choice == .moveRegular ? "Main" : ""
            routeLinks = model.settings.routeLinks
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .claudeDesktop: desktop
        case .firstProfile: firstProfile
        case .links: links
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: -10) {
                ProfileBadge(letter: "W", color: .blue, size: 56)
                ProfileBadge(letter: "P", color: .green, size: 56)
                ProfileBadge(letter: "C", color: .orange, size: 56)
            }
            Text("Several Claude accounts, side by side").font(.largeTitle.bold())
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                GridRow {
                    feature("square.stack.3d.up", "An app for each account", "Every profile keeps its own sign-in, chats and settings.")
                    feature("checkmark.shield", "Claude itself isn't modified", "Profiles launch your installed Claude, so updates keep working.")
                }
                GridRow {
                    feature("paintpalette", "Easy to tell apart", "Colored icons, window borders and keyboard shortcuts.")
                    feature("chevron.left.forwardslash.chevron.right", "Free and open source", "MIT licensed. No accounts, tracking or network calls.")
                }
            }
            Text("Each profile needs its own Claude account. This app doesn't provide access to Claude or change usage limits.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).font(.title3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var desktop: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Checking for Claude").font(.largeTitle.bold())
            Form {
                if let info = model.services.claudeDesktop() {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Claude Desktop is installed").fontWeight(.semibold)
                            Text("\(model.abbreviated(info.appURL)) · version \(info.version)")
                                .font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                    }
                } else {
                    NoticeRow(style: .critical, title: "Claude Desktop wasn't found",
                              message: "Install it from claude.ai/download, then continue. Profiles open your installed copy.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 90)
            Text("Each profile opens that same Claude with a separate data folder, so updates, Claude in Chrome and Claude Code keep working everywhere.")
                .foregroundStyle(.secondary)
        }
    }

    private var firstProfile: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create your first profile").font(.largeTitle.bold())
            SourceChoiceList(selection: $choice, choices: [.moveRegular, .empty, .restore, .later],
                             recommended: model.services.regularClaudeHasData() ? .moveRegular : nil)
            if choice != .later {
                Form {
                    if choice == .restore {
                        LabeledContent {
                            Button(backupURL == nil ? "Choose Backup…" : "Change…") { choosingBackup = true }
                        } label: {
                            Text("Backup file")
                            Text(backupURL?.lastPathComponent ?? "None chosen")
                        }
                    }
                    ProfileIdentityFields(name: $name, color: $color, nameError: nameError)
                    if choice == .moveRegular && model.isRunning(.regular) {
                        NoticeRow(style: .warning, title: "Regular Claude is running", message: "It will be quit before its data moves.")
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(minHeight: 200)
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose where links open").font(.largeTitle.bold())
            Text("Links that start with claude:// (from the web or other apps) normally go to regular Claude. This app can route them instead.")
                .foregroundStyle(.secondary)
            Form {
                Toggle(isOn: $routeLinks) {
                    Text("Route claude:// links")
                    Text("None open: regular Claude. One open: that one. Several open: you pick.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 90)
            Text("You can change this later in Settings. Turning it off hands links back to Claude.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Navigation

    private var nameError: String? {
        name.isEmpty ? nil : model.services.validateName(name, excluding: nil)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .claudeDesktop: "Continue"
        case .firstProfile:
            if creating { "Working…" }
            else if choice == .later { "Continue" }
            else if choice == .moveRegular && model.isRunning(.regular) { "Quit Claude and Move" }
            else { "Create Profile" }
        case .links: "Done"
        }
    }

    private var primaryEnabled: Bool {
        guard step == .firstProfile, choice != .later else { return !creating }
        if creating || name.trimmingCharacters(in: .whitespaces).isEmpty || nameError != nil { return false }
        return choice != .restore || backupURL != nil
    }

    private func primary() {
        switch step {
        case .welcome, .claudeDesktop:
            withAnimation { step = Step(rawValue: step.rawValue + 1)! }
        case .firstProfile:
            guard choice != .later else { withAnimation { step = .links }; return }
            let source: NewProfileSource = switch choice {
            case .moveRegular: .moveRegular
            case .restore: .restore(backupURL!)
            default: .empty
            }
            creating = true
            model.createProfile(name: name, color: color, source: source) { ok in
                creating = false
                if ok { withAnimation { step = .links } }
            }
        case .links:
            if routeLinks != model.settings.routeLinks { model.saveSettings { $0.routeLinks = routeLinks } }
            finish()
        }
    }

    private func finish() {
        model.completeOnboarding()
        dismiss()
    }
}
