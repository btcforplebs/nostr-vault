import SwiftUI

/// In a chat with someone you blocked (B3): why it is empty and the message
/// box is off, and where to undo it. The header opens their profile.
struct DMBlockedNotice: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.appSystem(size: 28))
                .foregroundColor(.secondary)
            Text("You blocked this person")
                .font(.appSystem(size: 15, weight: .semibold))
            Text("Messages to and from them are hidden. Unblock them on their profile to chat.")
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
    }
}
