import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// "Delete Account" at the bottom of an account's own page (Settings ›
/// Accounts › the account). Deletes that account from this device only and
/// sends nothing to relays. Another account: its key or signer link, its
/// settings and its cache files (`ConfigService.removeAccount`); the other
/// accounts stay. The main account: the vault's owner, so the whole device
/// goes (the Factory Reset wipe, `LeaveNostrService.wipeThisDevice`), and the
/// screen names every account that goes with it. Leave Nostr Forever
/// (Advanced) is the one that asks relays to erase.
struct DeleteAccountView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    let npub: String
    /// Closes this screen; `deleted` is true when the account is gone.
    var onDone: (_ deleted: Bool) -> Void

    @State private var typed = ""
    @State private var working = false
    @State private var refused: String?

    private var isOwner: Bool { npub == configService.config.ownerNpub }
    private var hasKey: Bool {
        isOwner ? !configService.config.ownerNcryptsec.isEmpty : configService.hasCredential(forNpub: npub)
    }
    private var hasSigner: Bool { configService.hasBunkerConfig(forNpub: npub) }
    private var others: [String] { configService.allAccountNpubs.filter { $0 != npub && !$0.isEmpty } }

    private func name(of npub: String) -> String {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let best = nostrService.profiles[hex]?.bestName ?? ""
        return best.isEmpty ? (npub.count > 20 ? "\(npub.prefix(12))\u{2026}\(npub.suffix(6))" : npub) : best
    }

    private static var device: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            ScrollView { content.padding(24) }
            Divider()
            buttons.padding(16)
        }
        .frame(width: 500, height: 560)
        .interactiveDismissDisabled(working)
        #else
        NavigationStack {
            ScrollView { content.padding(20) }
                .safeAreaInset(edge: .bottom) { buttons.padding().background(.bar) }
                .navigationTitle("Delete Account")
                .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(working)
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isOwner ? "Delete your main account" : "Delete this account")
                .font(.appTitle2.bold())
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 4) {
                Text(name(of: npub)).font(.appHeadline)
                Text(npub).font(.appCaption.monospaced()).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))

            if isOwner { ownerLines } else { otherLines }

            Text("Nothing is sent to relays: your notes and profile stay on them. To also ask relays to erase this account, use Settings \u{203A} Advanced \u{203A} Leave Nostr Forever.")
                .font(.appCallout)
                .foregroundColor(.secondary)

            Text(undoLine).font(.appCallout.bold())

            if let refused {
                Text(refused).font(.appCallout).foregroundColor(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Type \(LeaveNostr.confirmWord) to confirm").font(.appCallout)
                TextField(LeaveNostr.confirmWord, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .accessibilityLabel("Type DELETE to confirm")
            }
            if working { ProgressView("Deleting\u{2026}") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var ownerLines: some View {
        Text("This is your main account. Deleting it deletes its vault, and with it everything Nostr Vault keeps on this \(Self.device):")
            .font(.appBody).fixedSize(horizontal: false, vertical: true)
        if hasKey { bullet("Its private key.") }
        if hasSigner { bullet("Its link to your remote signer (the key stays in the signer).") }
        bullet("Your vault: every note, photo and file it stores on this \(Self.device).")
        bullet("Your settings and linked devices.")
        if !others.isEmpty {
            bullet("Your other \(others.count == 1 ? "account" : "accounts") on this \(Self.device) (\(others.map(name(of:)).joined(separator: ", "))), because \(others.count == 1 ? "it lives" : "they live") in the main account's vault.")
        }
    }

    @ViewBuilder
    private var otherLines: some View {
        Text("This deletes the account from this \(Self.device):")
            .font(.appBody)
        if hasKey { bullet("Its private key.") }
        if hasSigner { bullet("Its link to its remote signer (the key stays in the signer).") }
        bullet("Its settings, and the files Nostr Vault keeps for it (drafts, caches).")
        Text("Your other accounts stay. Notes from it already saved in your vault stay there.")
            .font(.appCallout)
    }

    private var undoLine: String {
        guard hasKey else { return "This can't be undone on this \(Self.device)." }
        return "This can't be undone. Unless you saved a copy of the private key somewhere else, it is gone for good, and no one can sign in as this account again."
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\u{2022}").font(.appBody)
            Text(text).font(.appBody).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") { onDone(false) }
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            Spacer()
            Button(role: .destructive) { delete() } label: {
                Text("Delete Account").bold()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(working || !LeaveNostr.confirms(typed))
        }
    }

    private func delete() {
        guard LeaveNostr.confirms(typed), !working else { return }
        guard isOwner else {
            configService.removeAccount(npub: npub)
            onDone(true)
            return
        }
        working = true
        refused = nil
        // Closed first: once the account is gone the screen would otherwise
        // come back blank over setup. The Mac app quits after the wipe.
        LeaveNostrService.wipeThisDevice(configService: configService, relayManager: RelayProcessManager.shared, willWipe: {
            #if os(iOS)
            onDone(true)
            #endif
        }, refused: { why in
            working = false
            refused = why
        })
    }
}
