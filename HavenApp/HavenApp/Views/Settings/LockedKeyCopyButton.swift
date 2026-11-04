import SwiftUI

/// Reveal Private Key's second copy: the key locked with the password just
/// typed (NIP-49 ncryptsec), the safe one to take to another app (NDK check
/// step 4, Logen 2026-11-04). Twin of Android `LockedKeyCopyButton.kt`.
struct LockedKeyCopyButton: View {
    let ncryptsec: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                PlatformClipboard.copy(ncryptsec)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { copied = false }
                }
            } label: {
                Label(copied ? "Copied!" : "Copy locked key (ncryptsec)",
                      systemImage: copied ? "checkmark" : "lock.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("revealKey.copyLocked")

            Text(LockedKeyExport.caption)
                .font(.appCaption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
