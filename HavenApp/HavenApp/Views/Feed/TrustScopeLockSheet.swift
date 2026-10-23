import SwiftUI

/// Why the Everyone switch is locked, and how far along unlocking it is:
/// shown instead of the sensitive-content warning while the account follows
/// fewer than `TrustScopeLock.followsNeeded` people. Android's twin is
/// TrustScopeLockSheet.kt.
struct TrustScopeLockSheet: View {
    let followCount: Int
    @Environment(\.dismiss) private var dismiss

    private var shown: Int { min(followCount, TrustScopeLock.followsNeeded) }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.appSystem(size: 40, weight: .semibold))
                .foregroundColor(.havenPurple)
                .accessibilityHidden(true)
            Text("Everyone is locked")
                .font(.appSystem(size: 20, weight: .bold))
            Text("Your Web of Trust keeps spam and sensitive posts out of Global. Everyone shows posts from anyone, unfiltered, so it opens once you follow \(TrustScopeLock.followsNeeded) people.")
                .font(.appSystem(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ProgressView(value: Double(shown), total: Double(TrustScopeLock.followsNeeded))
                    .tint(.havenPurple)
                Text("\(shown) of \(TrustScopeLock.followsNeeded) follows")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            Text(TrustScopeLock.progressText(followCount: followCount))
                .font(.appSystem(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
            Button { dismiss() } label: {
                Text("OK")
                    .font(.appSystem(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.havenPurple)
                    .cornerRadius(10)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: 420)
        #if os(macOS)
        .frame(width: 380)
        #else
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        #endif
    }
}

extension FeedService {
    /// The active account's follows, as the Everyone lock counts them.
    var trustLockFollowCount: Int {
        TrustScopeLock.followCount(followedPubkeys, me: ConfigService.shared.activeAccountHexPubkey)
    }
}
