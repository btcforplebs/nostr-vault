import SwiftUI

/// The inbox while its messages are still coming in (B7): launch, account
/// switch, or relays not answering. "No Messages Yet" only shows once the
/// relays have answered. After a while it says the relays aren't answering.
struct DMInboxLoadingView: View {
    @State private var slow = false

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(slow ? "Your message relays aren't answering yet." : "Loading messages…")
                .font(.appSystem(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            slow = true
        }
    }
}
