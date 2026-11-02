import SwiftUI

// MARK: - Skeleton Loading Row

/// A placeholder note row: neutral grey blocks with a light sweep across
/// them while the feed loads (FeedLoadingRows). Reduce Motion keeps it still.
struct FeedNoteSkeletonRow: View {
    @State private var sweep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 100, height: 12)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 60, height: 10)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(width: 180, height: 12)
            }

            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 28, height: 28)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.platformSeparator.opacity(ConfigService.shared.config.useOLED ? 1.5 : 1.0), lineWidth: ConfigService.shared.config.useOLED ? 1.5 : 0.8))
        .overlay {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, Color.primary.opacity(0.07), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.6)
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(Self.sweepAnimation, value: sweep)
        // Gated, not just un-animated: with Reduce Motion the sweep would jump
        // to the far edge and stay there.
        .onAppear { if Self.sweepAnimation != nil { sweep = true } }
        .accessibilityHidden(true)
    }

    /// Left to right, again and again, never back: a sweep, not a pulse.
    static var sweepAnimation: Animation? {
        Motion.isReduced ? nil : .linear(duration: 1.4).repeatForever(autoreverses: false)
    }
}

/// Five placeholder rows in place of a feed that hasn't loaded yet. Replaces
/// the Synchronizing / Analyzing / Finding Popular screens, and shows only
/// until the first relay answers (FeedSpeedPolicy.showsLoadingRows).
struct FeedLoadingRows: View {
    var count = 5

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<count, id: \.self) { _ in
                    FeedNoteSkeletonRow()
                        .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading posts"))
    }
}
