import SwiftUI

/// Pay or zap from the share sheet: shows what will be paid and nothing
/// else. No amount is set here and nothing is paid; the app's review card
/// shows the amount and asks before the wallet is touched.
struct PayShareForm: View {
    let input: NVShareInput
    let send: () -> Void

    private var target: String? {
        PayShareTarget.find(url: input.url, text: input.text, selection: input.selection)?.token
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pay or zap").font(.subheadline.weight(.semibold))
            if let target {
                Text(target)
                    .font(.caption.monospaced())
                    .lineLimit(2).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            Button(action: send) {
                Text("Send to Nostr Vault").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(target == nil)
            Text("Nothing is paid from here. The app shows the amount and asks before your wallet sends anything.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
