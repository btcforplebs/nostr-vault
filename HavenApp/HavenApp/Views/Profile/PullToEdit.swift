import SwiftUI

#if os(iOS)
// MARK: - Pull to edit

extension View {
    /// Pulling the top of the page down past a mark and letting go calls
    /// `onTrigger`. A label in the space the pull opens says what letting go
    /// will do. Needs scroll geometry, so iOS 17 keeps the button only.
    @ViewBuilder
    func pullToEdit(isEnabled: Bool, onTrigger: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *), isEnabled {
            modifier(PullToEditModifier(onTrigger: onTrigger))
        } else {
            self
        }
    }
}

/// How far the page is pulled past its top. A reference held in `@State`, so
/// the per-frame writes redraw only the label, not the profile.
private final class PullToEditState: ObservableObject {
    static let threshold: CGFloat = 96

    @Published private(set) var distance: CGFloat = 0
    var isArmed: Bool { distance >= Self.threshold }

    func update(_ newDistance: CGFloat) {
        // Rounded so a resting page publishes nothing.
        let rounded = newDistance.rounded()
        guard rounded != distance else { return }
        let wasArmed = isArmed
        distance = rounded
        if isArmed && !wasArmed {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}

@available(iOS 18.0, *)
private struct PullToEditModifier: ViewModifier {
    let onTrigger: () -> Void

    @State private var pull = PullToEditState()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                max(0, -(geo.contentOffset.y + geo.contentInsets.top))
            } action: { _, distance in
                pull.update(distance)
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                // Let go past the mark. Pulling back above it first cancels.
                if oldPhase == .interacting, newPhase != .interacting, pull.isArmed {
                    onTrigger()
                }
            }
            .overlay(alignment: .top) {
                // The overlay keeps to the safe area, so this sits just under
                // the bars, over the banner as it comes down.
                PullToEditLabel(pull: pull)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
    }
}

private struct PullToEditLabel: View {
    @ObservedObject var pull: PullToEditState

    var body: some View {
        let progress = min(pull.distance / PullToEditState.threshold, 1)
        HStack(spacing: 6) {
            Image(systemName: pull.isArmed ? "pencil.circle.fill" : "pencil")
                .font(.appSystem(size: 13, weight: .bold))
            Text(pull.isArmed ? "Release to edit profile" : "Pull to edit profile")
                .font(.appSystem(size: 13, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .frame(height: 32)
        // It lands on the banner, which can be any picture: a dark disc
        // until armed, then the accent.
        .background(Capsule().fill(pull.isArmed ? Color.havenPurple : Color.black.opacity(0.6)))
        .opacity(Double(max(0, progress * 1.6 - 0.2)))
        .scaleEffect(0.85 + 0.15 * progress)
        .animation(Motion.fade, value: pull.isArmed)
        .accessibilityHidden(true)
    }
}
#endif
