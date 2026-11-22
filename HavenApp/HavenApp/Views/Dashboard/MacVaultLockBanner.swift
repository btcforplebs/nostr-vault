#if os(macOS)
import SwiftUI

/// Vault Dashboard › Status, Mac only: what the phone's one "Restart vault"
/// button stands for when the vault needs fixing. Carried over from the Mac
/// relay console's recovery banner (DashboardView+StatusHeader) so the fold
/// into the one Vault loses nothing: Force Restart, Clear Locks Only for a
/// stale database lock, and where the port lives for a port conflict.
struct MacVaultLockBanner: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(relayManager.isPortConflict
                ? "Another app is in your vault's way. Close other copies of Nostr Vault or restart your computer. The port is under Settings › Advanced."
                : "A previous session did not shut down cleanly. Clear the locks to start your vault again.")
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    relayManager.forceCleanAndRestart()
                } label: {
                    Label("Force Restart", systemImage: "arrow.clockwise")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(.onAccent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 36)
                        .background(Color.havenPurple, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                if relayManager.isLocked {
                    Button("Clear Locks Only") {
                        relayManager.clearLocksAndStart(config: configService.config)
                    }
                    .buttonStyle(.plain)
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .help("Removes the stale lock files and starts the vault, without a full clean-up")
                }
            }
        }
    }
}
#endif
