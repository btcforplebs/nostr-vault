import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

#if os(iOS)
/// Pick a kiosk phone of your own as the home vault: your notes and media go
/// to it over the FIPS mesh as well as to this phone's relay.
struct HomeVaultSection: View {
    @ObservedObject private var sender = HomeVaultSender.shared
    @ObservedObject private var nostr = NostrService.shared
    @State private var draft = ""
    @State private var showScanner = false

    private var owner: String { nostr.activeHexPubkey }
    private var choices: [String] {
        HomeVaultSender.meshEntries(serverList: nostr.serverLists[owner] ?? [])
    }
    private var selection: Binding<String> {
        Binding(
            get: { sender.homeVault?.ownerHex == owner ? (sender.homeVault?.meshNpub ?? "") : "" },
            set: { npub in
                sender.setHomeVault(npub.isEmpty ? nil : .init(ownerHex: owner, meshNpub: npub))
            }
        )
    }

    var body: some View {
        Section {
            Picker("Home vault", selection: selection) {
                Text("Off").tag("")
                ForEach(choices, id: \.self) { npub in
                    Text(npub.prefix(12) + "…" + npub.suffix(6)).tag(npub)
                }
                // Keep a chosen vault visible even if it left the server list.
                if let chosen = sender.homeVault?.meshNpub, sender.homeVault?.ownerHex == owner, !choices.contains(chosen) {
                    Text(chosen.prefix(12) + "… (not listed now)").tag(chosen)
                }
            }
            HStack {
                TextField("Paste a kiosk's mesh address", text: $draft)
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
                .accessibilityLabel("Scan the kiosk's QR code")
            }
            if !draft.isEmpty {
                if HomeVaultLogic.meshNpub(fromInput: draft) == nil {
                    Text("That isn't a mesh address. Copy it from the kiosk's FIPS Mesh settings.")
                        .font(.appCaption)
                        .foregroundColor(.orange)
                } else {
                    Button("Use this address", action: useDraft)
                        .font(.appCaption)
                }
            }
            if choices.isEmpty && sender.homeVault == nil {
                Text("Turn on kiosk mode on your other phone, then scan or paste the mesh address it shows.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            if sender.homeVault != nil {
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
            }
        } header: {
            Text("Home Vault")
        } footer: {
            Text("New notes and media also go to your kiosk phone over the mesh, and it sends your notes on to your relays. They stay on this phone too. What can't reach it waits here and goes when Nostr Vault is open and the kiosk is in reach. Picking a home vault lists its mesh address in your Blossom server list, in public. The kiosk must let your account write to its relay.")
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                title: "Scan the kiosk's mesh address",
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
        sender.setHomeVault(.init(ownerHex: owner, meshNpub: npub))
        draft = ""
    }

    static func qrImage(for string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

#endif
