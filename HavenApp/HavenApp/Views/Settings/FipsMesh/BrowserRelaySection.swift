import SwiftUI

#if os(iOS)
/// Hand your notes to a browser relay: a nostrvault.app page that keeps no
/// key. This phone joins the mesh, the page finds it, and your notes go to
/// the page already signed.
struct BrowserRelaySection: View {
    @ObservedObject private var sender = BrowserRelaySender.shared
    @ObservedObject private var mesh = FipsMeshService.shared
    @ObservedObject private var nostr = NostrService.shared
    @State private var draft = ""
    @State private var showScanner = false
    @State private var connecting = false

    private var owner: String { nostr.activeHexPubkey }
    private var relayForOwner: BrowserRelaySender.BrowserRelay? {
        sender.relay?.ownerHex == owner ? sender.relay : nil
    }

    var body: some View {
        Section {
            if let relay = relayForOwner {
                LabeledContent("Browser relay", value: relay.meshNpub.prefix(12) + "…" + relay.meshNpub.suffix(6))
                if let npub = mesh.status?.relay_link == true ? mesh.ownMeshNpub : nil {
                    Text("This phone's mesh address. Paste it into the page under Vault mesh address, Save vaults, then Start FIPS:")
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
                Button("Remove browser relay", role: .destructive) { sender.setRelay(nil) }
                    .font(.appCaption)
            } else if sender.relay != nil {
                // Set up under another account. It still makes the mesh join the
                // public seeds, so it must stay removable from here.
                Text("A browser relay is set up for another account on this phone.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                Button("Remove browser relay", role: .destructive) { sender.setRelay(nil) }
                    .font(.appCaption)
            } else {
                HStack {
                    TextField("Paste the page's mesh address", text: $draft)
                        .font(.appSystem(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(useDraft)
                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Scan the page's mesh address")
                }
                if !draft.isEmpty {
                    if HomeVaultLogic.meshNpub(fromInput: draft) == nil {
                        Text("That isn't a mesh address. Copy it from the top of the page's Relay screen.")
                            .font(.appCaption)
                            .foregroundColor(.orange)
                    } else {
                        Button("Use this address", action: useDraft)
                            .font(.appCaption)
                    }
                }
            }
            if let error = mesh.lastError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("Browser Relay")
        } footer: {
            Text("Your new notes also go to a Nostr Vault page in a browser, over the mesh, while this app is open. The page keeps no key: it stores notes you already signed and checks each one. To connect, this phone joins two public mesh servers (fips1 and fips2.iris.to), which see its IP address the way any server does. While a browser relay is set up, it joins them whenever the mesh is on, kiosk mode and home vault included. Nothing is listed in public.")
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                title: "Scan the page's mesh address",
                validate: { HomeVaultLogic.meshNpub(fromInput: $0) == nil ? "That QR code is not a mesh address" : nil }
            ) { code in
                showScanner = false
                draft = code
                useDraft()
            }
        }
    }

    private func useDraft() {
        guard let npub = HomeVaultLogic.meshNpub(fromInput: draft) else { return }
        guard npub != FipsMeshService.shared.ownMeshNpub else { return }
        sender.setRelay(.init(ownerHex: owner, meshNpub: npub))
        draft = ""
        // Start (or restart) the engine with the relay link, so the page can find this phone.
        connecting = true
        Task {
            _ = await mesh.connectForBrowserRelay()
            connecting = false
        }
    }
}
#endif
