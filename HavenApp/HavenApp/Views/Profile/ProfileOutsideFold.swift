import SwiftUI

/// "N tagged notes from outside your web" over a profile's Tagged tab: the
/// same fold a thread puts under its replies. Tap to show them among the
/// rest, tap again to fold them away. With "Show Outside your web under
/// posts" off there is no fold: those notes are only in the Vault's Outside
/// list.
struct ProfileOutsideFold: View {
    @ObservedObject var loader: ProfileFeedLoader
    let folds: Bool

    var body: some View {
        let count = loader.buckets.taggedOutside.count
        if folds && count > 0 {
            let open = loader.showsOutsideTagged
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { loader.showsOutsideTagged.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "eye" : "eye.slash")
                    Text(TrustGate.outsideLabel(count: count, noun: "tagged note"))
                        .font(.appSystem(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.appSystem(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityHint(Text(open ? "Hides them again" : "Shows them in the list"))
            .accessibilityIdentifier("profile.taggedOutsideYourWeb")
        }
    }
}
