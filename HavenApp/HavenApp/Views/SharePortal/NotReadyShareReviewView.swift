import SwiftUI

/// The review card for an action whose handler is still a stub.
struct NotReadyShareReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: intent.action.systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Not ready yet")
                .font(.headline)
            Text("\(intent.action.title) isn't something Nostr Vault can do yet. Nothing was posted.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("OK", action: close)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
