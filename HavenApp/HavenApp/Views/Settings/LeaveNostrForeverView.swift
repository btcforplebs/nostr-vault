import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Settings › Advanced › "Leave Nostr Forever": the owner's account is
/// erased from Nostr as far as this app can ask, then from this device.
/// Three warnings on separate screens; the last one unlocks only when the
/// account's name is typed and the button is held for `LeaveNostr.holdSeconds`.
/// Every line on screen says what `LeaveNostrService` does, in its order.
struct LeaveNostrForeverView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var nostrService: NostrService
    @ObservedObject var relayManager: RelayProcessManager
    var onDismiss: () -> Void

    @State private var typed = ""
    @State private var phase: Phase = .confirm
    /// Which of the three warning screens is showing (1...3).
    @State private var screen = 1

    private enum Phase: Equatable {
        case confirm
        case sending
        case wiping(String)
        case failed(String)
        /// No relay took the erase request: the person chooses (LeaveNostr.mayWipe).
        case noneAccepted(String)
    }

    private var usesSigner: Bool { configService.config.ownerSignsWithBunker }

    /// Delete Account always erases the owner (main) account; the active one
    /// may be another. Both are named so nobody erases the wrong identity.
    private var ownerNpub: String { configService.config.ownerNpub }
    private var activeNpub: String {
        let active = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return active.isEmpty ? ownerNpub : active
    }
    private func name(of npub: String) -> String {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let best = nostrService.profiles[hex]?.bestName ?? ""
        return best.isEmpty ? Self.short(npub) : best
    }
    private static func short(_ npub: String) -> String {
        npub.count > 20 ? "\(npub.prefix(12))\u{2026}\(npub.suffix(6))" : npub
    }
    private var nameToType: String {
        let hex = Bech32.decode(ownerNpub)?.hexString ?? ""
        return LeaveNostr.nameToType(name: nostrService.profiles[hex]?.bestName ?? "", npub: ownerNpub)
    }
    private var nameTyped: Bool { LeaveNostr.nameConfirms(typed, expected: nameToType) }
    private var otherAccounts: Int { max(configService.allAccountNpubs.count - 1, 0) }
    private var busy: Bool {
        switch phase {
        case .sending, .wiping: return true
        default: return false
        }
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
        .frame(width: 520, height: 640)
        .interactiveDismissDisabled(busy)
        #else
        NavigationStack {
            ScrollView { content.padding(20) }
                .safeAreaInset(edge: .bottom) { buttons.padding().background(.bar) }
                .navigationTitle("Leave Nostr Forever")
                .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(busy)
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Warning \(screen) of 3").font(.appCaption.bold()).foregroundColor(.red)
            switch screen {
            case 1: firstWarning
            case 2: secondWarning
            default: lastWarning
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 1 of 3: whose account, and what is about to happen.
    @ViewBuilder
    private var firstWarning: some View {
        Text("Leave Nostr Forever")
            .font(.appTitle2.bold())
            .accessibilityAddTraits(.isHeader)
        accountCard
        Text("This is about to happen:").font(.appHeadline)
        step(1, "Your profile is blanked, so people see the account is gone.")
        step(2, "We ask every relay you use, and your vault, to erase all your notes and your profile (a Nostr \u{201C}erase me\u{201D} request, signed by \(usesSigner ? "your signer" : "you")).")
        step(3, thirdStep)
        if usesSigner {
            Text("Your account signs with a remote signer: it signs both requests, then this \(Self.device) disconnects from it. Your key stays in the signer.")
                .font(.appCallout)
        }
    }

    /// 2 of 3: what the request can't reach.
    @ViewBuilder
    private var secondWarning: some View {
        Text("Not everything can be erased")
            .font(.appTitle2.bold())
            .accessibilityAddTraits(.isHeader)
        Text("Most relays honour the request. Some may not, and we can't force them.").font(.appBody)
        Text("Photos you put on outside media servers are not covered by the request.").font(.appBody)
        Text("Copies other people saved stay with them.").font(.appBody)
        Text("To delete the account from this \(Self.device) only, without telling relays, cancel and use Delete Account on its page (Settings \u{203A} Accounts).")
            .font(.appCallout)
            .foregroundColor(.secondary)
    }

    /// 3 of 3: no way back. Type the name, then hold.
    @ViewBuilder
    private var lastWarning: some View {
        Text("There is no way back")
            .font(.appTitle2.bold())
            .accessibilityAddTraits(.isHeader)
        accountCard
        Text(undoLine).font(.appCallout.bold())
        if case .confirm = phase { confirmField }
        if case .failed(let message) = phase {
            Text(message).font(.appCallout).foregroundColor(.red)
            confirmField
        }
        if case .sending = phase {
            ProgressView("Sending the erase request\u{2026}")
        }
        if case .noneAccepted(let summary) = phase {
            Text(summary + ".").font(.appCallout)
            Text("No relay took the erase request, so nothing has been deleted yet. If you delete now, your key goes with it and the request can never be sent again. Try again when you're online, or delete from this \(Self.device) only.")
                .font(.appCallout)
                .foregroundColor(.red)
        }
        if case .wiping(let summary) = phase {
            Text(summary + ".").font(.appCallout)
            ProgressView("Deleting everything on this \(Self.device)\u{2026}")
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Account to erase").font(.appCaption).foregroundColor(.secondary)
            Text(name(of: ownerNpub)).font(.appHeadline)
            Text(ownerNpub).font(.appCaption.monospaced()).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if activeNpub != ownerNpub {
                Text("This erases your main account, \(name(of: ownerNpub)), not \(name(of: activeNpub)), the account you are using now.")
                    .font(.appCallout.bold())
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
    }

    private var thirdStep: String {
        var line = "Your private key and everything Nostr Vault stores on this \(Self.device) are deleted: your vault's notes, photos and files, your settings and linked devices."
        if usesSigner {
            line = "Everything Nostr Vault stores on this \(Self.device) is deleted: your vault's notes, photos and files, your settings and linked devices."
        }
        if otherAccounts > 0 {
            line += " The \(otherAccounts == 1 ? "other account" : "\(otherAccounts) other accounts") on this \(Self.device) \(otherAccounts == 1 ? "is" : "are") removed from it too (no erase request is sent for \(otherAccounts == 1 ? "it" : "them"))."
        }
        return line
    }

    private var undoLine: String {
        if usesSigner { return "This can't be undone on this \(Self.device)." }
        return "This can't be undone. Unless you saved a copy of your private key somewhere else, it is gone for good, and no one, not even you, can sign in as this account again."
    }

    private var confirmField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type \(nameToType) to confirm, then hold the button for \(Int(LeaveNostr.holdSeconds)) seconds.").font(.appCallout)
            TextField(nameToType, text: $typed)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel("Type \(nameToType) to confirm")
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").font(.appBody.monospacedDigit().bold())
            Text(text).font(.appBody).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if case .noneAccepted = phase {
            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive) { wipe() } label: {
                    Text("Delete from this \(Self.device) only")
                }
                Button { leave() } label: { Text("Try Again").bold() }
                    .buttonStyle(.borderedProminent)
                    .tint(.havenPurple)
            }
        } else if screen < 3 {
            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if screen > 1 { Button("Back") { screen -= 1 } }
                Button { screen += 1 } label: { Text("Continue").bold() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        } else {
            VStack(spacing: 10) {
                HoldToConfirmButton(title: "Hold to Leave Nostr Forever", seconds: LeaveNostr.holdSeconds,
                                    enabled: !busy && nameTyped) { leave() }
                HStack {
                    Button("Cancel") { onDismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(busy)
                    Spacer()
                    Button("Back") { screen = 2 }.disabled(busy)
                }
            }
        }
    }

    private func leave() {
        guard screen == 3, nameTyped, !busy else { return }
        phase = .sending
        Task { @MainActor in
            switch await LeaveNostrService.sendEraseRequest(configService: configService, nostrService: nostrService) {
            case .failure(let why):
                phase = .failed(why.message + " To delete it from this \(Self.device) only, without telling relays, use Delete Account on its page (Settings \u{203A} Accounts).")
            case .success(let tally):
                guard LeaveNostr.mayWipe(after: tally) else {
                    phase = .noneAccepted(tally.summary)
                    return
                }
                phase = .wiping(tally.summary)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                finishWipe()
            }
        }
    }

    /// "Delete from this device only", after no relay took the request.
    private func wipe() {
        guard case .noneAccepted(let summary) = phase else { return }
        phase = .wiping(summary)
        finishWipe()
    }

    private func finishWipe() {
        // Closed first: once the account is gone the screen would otherwise
        // come back blank over setup. Stays open, saying why, if the vault
        // was too busy to delete anything.
        LeaveNostrService.wipeThisDevice(configService: configService, relayManager: relayManager, willWipe: {
            #if os(iOS)
            onDismiss()
            #endif
        }, refused: { phase = .failed($0) })
    }
}
