import SwiftUI
import CMACore

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 520)
        .tracksActivationPolicy()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: setting(\.launchAtLogin))
                Toggle(isOn: setting(\.showLetterInMenuBar)) {
                    Text("Show the front profile's letter in the menu bar")
                    Text("Replaces the menu bar icon with the first letter of the profile you're using.")
                }
            }
            Section {
                Toggle(isOn: setting(\.routeLinks)) {
                    Text("Route claude:// links")
                    Text("None open: regular Claude. One open: that one. Several open: you choose. Turning this off hands links back to Claude.")
                }
            } header: {
                Text("Links")
            }
            Section {
                Toggle(isOn: setting(\.pauseMusicWhileDictating)) {
                    Text("Pause Spotify while Claude uses the microphone")
                    Text("Resumes shortly after the microphone stops, and only if it was playing.")
                }
            } header: {
                Text("Music")
            }
            Section {
                Button("Show Welcome Again…") {
                    openWindow(id: WindowID.main)
                    model.activeSheet = .onboarding
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 420)
    }

    private func setting(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding {
            model.settings[keyPath: keyPath]
        } set: { value in
            model.saveSettings { $0[keyPath: keyPath] = value }
        }
    }
}

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    HStack(spacing: -8) {
                        ProfileBadge(letter: "C", color: .orange, size: 40)
                        ProfileBadge(letter: "M", color: .blue, size: 40)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppPaths.appName).font(.title3.bold())
                        Text("Version \(version)").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Text("Run several Claude Desktop accounts side by side, each in its own app.")
                    .foregroundStyle(.secondary)
            }
            Section("License") {
                Text(Self.license)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Free and open source. Not affiliated with Anthropic. Makes no network connections and collects no data.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 420)
    }

    static let license = """
    MIT License

    Copyright (c) 2026 Apollo Automation

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}
