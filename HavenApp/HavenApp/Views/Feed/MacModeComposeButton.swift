import SwiftUI

#if os(macOS)
/// The Mac's way into the Article and Recipe composers: the button iPhone
/// floats over every feed, shown on the Mac in the two feeds whose composer
/// had no other entry (parity sweep 2026-11-02, #22 and #23). Notes keep ⌘N /
/// New Post, diVines and polls keep the buttons in their own feeds.
struct MacModeComposeButton: View {
    let feedMode: FeedMode
    let canSign: Bool
    let open: (ModeComposer) -> Void

    /// Only these two: the others already have a way in on the Mac.
    static func composer(for mode: FeedMode) -> ModeComposer? {
        switch ModeComposer(feedMode: mode) {
        case .article?: return .article
        case .recipe?: return .recipe
        default: return nil
        }
    }

    var body: some View {
        if canSign, let composer = Self.composer(for: feedMode) {
            Button { open(composer) } label: {
                Label(composer.buttonTitle, systemImage: composer.symbolName)
                    .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(
                        Capsule()
                            .fill(LinearGradient(colors: [Color.havenPurple, Color.havenPurpleLight],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: Color.havenPurple.opacity(0.35), radius: 8, x: 0, y: 4)
                    )
            }
            .buttonStyle(.plain)
            .help(composer.accessibilityLabel)
            .accessibilityLabel(composer.accessibilityLabel)
            .padding(20)
        }
    }
}
#endif
