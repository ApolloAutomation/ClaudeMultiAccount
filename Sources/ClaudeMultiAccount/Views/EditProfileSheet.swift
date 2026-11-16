import SwiftUI
import CMACore

struct EditProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID

    @State private var draft: Profile?

    var body: some View {
        VStack(spacing: 0) {
            if let original = model.profile(profileID), draft != nil {
                let running = model.isRunning(.profile(profileID))
                Form {
                    ProfileIdentityFields(name: binding(\.name), color: binding(\.color),
                                          nameError: nameError, colorLocked: running)
                    Section("Window Border") {
                        Toggle("Colored border around Claude windows", isOn: binding(\.showBorder))
                        Picker("Thickness", selection: binding(\.borderWidth)) {
                            ForEach(BorderWidth.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(draft?.showBorder != true)
                    }
                    if draft?.name != original.name {
                        Section {
                            NoticeRow(style: .info, title: "Renaming updates everything",
                                      message: "The app, Dock entry, desktop shortcut and terminal command follow the new name.")
                        }
                    }
                }
                .formStyle(.grouped)
                .navigationTitle("Edit \(original.name)")

                SheetButtons {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { save() }
                        .primaryAction()
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft == original || nameError != nil || draft?.name.trimmingCharacters(in: .whitespaces).isEmpty != false)
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .frame(width: 480)
        .onAppear { draft = model.profile(profileID) }
    }

    private var nameError: String? {
        guard let draft else { return nil }
        return model.services.validateName(draft.name, excluding: profileID)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        Binding {
            draft![keyPath: keyPath]
        } set: {
            draft?[keyPath: keyPath] = $0
        }
    }

    private func save() {
        guard var draft else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        model.update(draft)
        dismiss()
    }
}
