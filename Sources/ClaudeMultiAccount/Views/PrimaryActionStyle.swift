import SwiftUI

extension View {
    /// Prominent glass button with a white label, so text stays legible on the accent fill
    /// (plain `.glassProminent` can render the label in the tint colour, i.e. blue on blue).
    func primaryAction() -> some View {
        buttonStyle(.glassProminent)
            .foregroundStyle(.white)
    }
}
