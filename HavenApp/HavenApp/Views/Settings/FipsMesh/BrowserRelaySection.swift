import SwiftUI

#if os(iOS)
/// The browser page's page in My Devices: connect this phone, copy its
/// address for the page, and send the latest notes. The page keeps no key;
/// your notes go to it already signed. Adding the page is Add a device.
struct BrowserRelaySection: View {
    @ObservedObject private var sender = BrowserRelaySender.shared
    @ObservedObject private var mesh = FipsMeshService.shared
    @ObservedObject private var nostr = NostrService.shared
    @State private var connecting = false

    private var isForOwner: Bool { sender.relay?.ownerHex == nostr.activeHexPubkey }

    var body: some View {
        Section {
            if !isForOwner {
                // Set up under another account. It still makes the mesh join the
                // public seeds, so it must stay removable from here.
                Text("This browser vault is set up for another account on this phone.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            } else {
                if let npub = mesh.status?.relay_link == true ? mesh.ownMeshNpub : nil {
                    Text("This phone's mesh address. Paste it into the page's mesh address box, put your Nostr account npub in the box below it, tap Save owners, then Start mesh:")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    Text(npub)
                        .font(.appSystem(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy this phone's mesh address") { UIPasteboard.general.string = npub }
                        .font(.appCaption)
                } else {
                    Button(connecting ? "Connecting…" : "Connect this phone") {
                        connecting = true
                        Task {
                            _ = await mesh.connectForBrowserRelay()
                            connecting = false
                        }
                    }
                    .disabled(connecting)
                }
                HStack {
                    Button("Send my latest notes") { Task { await sender.sendLatest() } }
                        .disabled(sender.sending)
                    Spacer()
                    if sender.sending { ProgressView() }
                }
                if let result = sender.lastResult {
                    Text(result)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            if let error = mesh.lastError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("Sending")
        } footer: {
            Text("Your new notes also go to your browser vault, a Nostr Vault page in a browser, over the mesh, while this app is open. The page keeps no key: it stores notes you already signed and checks each one. To connect, this phone joins the middle server (Mesh → Advanced), which sees its IP address the way any server does. While a browser vault is set up, it joins whenever the mesh is on, home vault mode included. Nothing is listed in public.")
        }
    }
}
#endif
