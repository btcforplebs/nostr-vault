import SwiftUI

#if os(iOS)
/// The home vault's page in My Devices: what waits to go to it, Send now, and
/// how the last send went. Picking the home vault is Add a device.
struct HomeVaultSection: View {
    @ObservedObject private var sender = HomeVaultSender.shared

    var body: some View {
        Section {
            HStack {
                Text(sender.queue.isEmpty ? "Nothing waiting" : "\(sender.queue.count) waiting to send")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                Spacer()
                if sender.sending {
                    ProgressView()
                } else if !sender.queue.isEmpty {
                    Button("Send now") { Task { await sender.drain(userInitiated: true) } }
                        .font(.appCaption)
                }
            }
            if ConfigService.shared.config.activeSigningMode() != "local" {
                Text("Your key is in a remote signer, so media only goes when you tap Send now (up to \(HomeVaultLogic.maxPromptsPerTap) at a time).")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            if let result = sender.lastResult {
                Text(result)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Sending")
        } footer: {
            Text("New notes and media also go to your kiosk phone over the mesh, and it sends your notes on to your relays. They stay on this phone too. What can't reach it waits here and goes when Nostr Vault is open and the kiosk is in reach. A home vault lists its mesh address in your Blossom server list, in public. The kiosk must let your account write to its relay.")
        }
    }
}
#endif
