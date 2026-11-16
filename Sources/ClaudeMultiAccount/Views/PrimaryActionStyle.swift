import SwiftUI

extension View {
    /// Primary action button. `.glassProminent` can draw its label in the tint colour
    /// (blue on blue, especially when the window is inactive), so use the system
    /// prominent style, which renders as Liquid Glass on macOS 26 with a white label.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
    }
}
