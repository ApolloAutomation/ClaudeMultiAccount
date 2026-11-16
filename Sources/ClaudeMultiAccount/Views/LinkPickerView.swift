import SwiftUI
import CMACore

struct LinkPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var choice: ClaudeTarget?

    var body: some View {
        Group {
            if let request = model.pendingLinks.first {
                picker(request)
                    .onAppear { choice = request.preselected ?? request.candidates.first }
                    .onChange(of: request.id) { choice = request.preselected ?? request.candidates.first }
            } else {
                Text("No link waiting.").foregroundStyle(.secondary).padding(40)
            }
        }
        .tracksActivationPolicy()
        .onChange(of: model.pendingLinks.isEmpty) { _, empty in
            if empty { dismissWindow(id: WindowID.linkPicker) }
        }
    }

    private func picker(_ request: LinkRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open this link in…").font(.title2.bold())
            Text(request.url.absoluteString)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))

            Picker("Claude", selection: $choice) {
                ForEach(request.candidates, id: \.self) { target in
                    HStack(spacing: 8) {
                        badge(target)
                        Text(model.displayName(target))
                        if target == request.preselected {
                            Text("last used").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(target))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack {
                if model.pendingLinks.count > 1 {
                    Text("\(model.pendingLinks.count - 1) more waiting").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.routePendingLink(to: nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { model.routePendingLink(to: choice) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440)
    }

    @ViewBuilder private func badge(_ target: ClaudeTarget) -> some View {
        switch target {
        case .regular: OutlineBadge(text: "R", size: 20)
        case .profile(let id):
            if let profile = model.profile(id) {
                ProfileBadge(letter: profile.initial, color: profile.color, size: 20)
            }
        }
    }
}
