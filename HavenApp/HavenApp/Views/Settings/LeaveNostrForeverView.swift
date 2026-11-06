import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// "Delete Account" › "Leave Nostr Forever": the owner's account is erased
/// from Nostr as far as this app can ask, then from this device. Every line
/// on screen says what `LeaveNostrService` does, in its order.
struct LeaveNostrForeverView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var nostrService: NostrService
    @ObservedObject var relayManager: RelayProcessManager
    var onDismiss: () -> Void

    @State private var typed = ""
    @State private var phase: Phase = .confirm

    private enum Phase: Equatable {
        case confirm
        case sending
        case wiping(String)
        case failed(String)
    }

    private var usesSigner: Bool { configService.config.ownerSignsWithBunker }
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
                .navigationTitle("Delete Account")
                .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(busy)
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Leave Nostr Forever")
                .font(.appTitle2.bold())
                .accessibilityAddTraits(.isHeader)

            Text("This is about to happen:").font(.appHeadline)

            step(1, "Your profile is blanked, so people see the account is gone.")
            step(2, "We ask every relay you use, and your vault, to erase all your notes and your profile (a Nostr \u{201C}erase me\u{201D} request, signed by \(usesSigner ? "your signer" : "you")).")
            step(3, thirdStep)

            if usesSigner {
                Text("Your account signs with a remote signer: it signs both requests, then this \(Self.device) disconnects from it. Your key stays in the signer.")
                    .font(.appCallout)
            }

            Text("Most relays honour the request. Some may not, and we can't force them. Photos you put on outside media servers are not covered by the request. Copies other people saved stay with them.")
                .font(.appCallout)
                .foregroundColor(.secondary)

            Text(undoLine)
                .font(.appCallout.bold())

            if case .confirm = phase { confirmField }
            if case .failed(let message) = phase {
                Text(message).font(.appCallout).foregroundColor(.red)
                confirmField
            }
            if case .sending = phase {
                ProgressView("Sending the erase request\u{2026}")
            }
            if case .wiping(let summary) = phase {
                Text(summary + ".").font(.appCallout)
                ProgressView("Deleting everything on this \(Self.device)\u{2026}")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("Type \(LeaveNostr.confirmWord) to confirm").font(.appCallout)
            TextField(LeaveNostr.confirmWord, text: $typed)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .accessibilityLabel("Type DELETE to confirm")
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").font(.appBody.monospacedDigit().bold())
            Text(text).font(.appBody).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(busy)
            Spacer()
            Button(role: .destructive) { leave() } label: {
                Text("Leave Nostr Forever").bold()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(busy || !LeaveNostr.confirms(typed))
        }
    }

    private func leave() {
        guard LeaveNostr.confirms(typed), !busy else { return }
        phase = .sending
        Task { @MainActor in
            switch await LeaveNostrService.sendEraseRequest(configService: configService, nostrService: nostrService) {
            case .failure(let why):
                phase = .failed(why.message + " To delete it from this \(Self.device) only, without telling relays, use Settings \u{203A} Advanced \u{203A} Factory Reset.")
            case .success(let tally):
                phase = .wiping(tally.summary)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // Closed first: once the account is gone the screen would
                // otherwise come back blank over setup. Stays open, saying
                // why, if the vault was too busy to delete anything.
                LeaveNostrService.wipeThisDevice(configService: configService, relayManager: relayManager, willWipe: {
                    #if os(iOS)
                    onDismiss()
                    #endif
                }, refused: { phase = .failed($0) })
            }
        }
    }
}
