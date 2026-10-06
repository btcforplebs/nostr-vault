import SwiftUI

/// One quiet line of numbers under a post: `♥ 24   ↻ 3   💬 7   ⚡ 2.1k`.
/// A count of zero is left out rather than shown as "0".
struct EngagementSummaryLine: View {
    let engagement: PostEngagement
    var showsLikes = true

    var body: some View {
        HStack(spacing: 14) {
            if showsLikes, engagement.likes > 0 {
                item("heart.fill", engagement.likes, tint: .pink, label: "likes")
            }
            if engagement.reposts > 0 {
                item("arrow.2.squarepath", engagement.reposts, tint: .green, label: "reposts")
            }
            if engagement.replies > 0 {
                item("bubble.left.fill", engagement.replies, tint: .havenPurple, label: "replies")
            }
            if engagement.zapSats > 0 {
                item("bolt.fill", engagement.zapSats, tint: .orange, label: "sats zapped")
            }
            Spacer(minLength: 0)
        }
        .font(.appSystem(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func item(_ symbol: String, _ value: Int, tint: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.appSystem(size: 10, weight: .semibold))
                .foregroundColor(tint.opacity(0.85))
            Text(engagement.display(value))
                .monospacedDigit()
        }
        .accessibilityLabel(engagement.isLowerBound && value >= PostEngagement.lowerBoundFrom ? "at least \(value) \(label)" : "\(value) \(label)")
    }
}
