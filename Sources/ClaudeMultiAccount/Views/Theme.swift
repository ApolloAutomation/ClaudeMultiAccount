import SwiftUI
import CMACore

extension ProfileColor {
    var color: Color {
        switch self {
        case .orange: .orange
        case .blue: .blue
        case .green: .green
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .teal: .teal
        case .gray: .gray
        }
    }
}

extension Profile {
    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
}

/// Rounded-square letter badge in the profile color, matching the generated app icon.
struct ProfileBadge: View {
    var letter: String
    var color: ProfileColor
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.color.gradient)
            .overlay {
                Text(letter)
                    .font(.system(size: size * 0.52, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Dashed outline badge for things that are not profiles (regular Claude, memory).
struct OutlineBadge: View {
    var text: String? = nil
    var symbol: String? = nil
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
            .overlay {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: size * 0.45, weight: .semibold))
                } else if let text {
                    Text(text).font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Small colored capsule describing whether an instance is running.
struct StatusCapsule: View {
    var state: RunState

    var body: some View {
        Label {
            Text(state.label)
        } icon: {
            Circle().fill(state.isRunning ? Color.green : Color.secondary).frame(width: 7, height: 7)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background((state.isRunning ? Color.green : Color.secondary).opacity(0.15), in: .capsule)
    }
}

struct ColorSwatchPicker: View {
    @Binding var selection: ProfileColor
    var disabled = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProfileColor.allCases, id: \.self) { color in
                Button {
                    selection = color
                } label: {
                    Circle()
                        .fill(color.color.gradient)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if selection == color {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(2)
                        .overlay(Circle().strokeBorder(selection == color ? color.color : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName)
                .accessibilityAddTraits(selection == color ? .isSelected : [])
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// Inline notice row used inside Form sections.
struct NoticeRow: View {
    enum Style { case info, warning, critical }
    var style: Style = .info
    var title: String
    var message: String? = nil

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                if let message { Text(message).foregroundStyle(.secondary).font(.callout) }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    private var symbol: String {
        switch style {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch style {
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Keeps the app's activation policy `.regular` while any window using this is visible.
struct TracksActivationPolicy: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content
            .onAppear { model.windowAppeared() }
            .onDisappear { model.windowDisappeared() }
    }
}

extension View {
    func tracksActivationPolicy() -> some View { modifier(TracksActivationPolicy()) }
}
