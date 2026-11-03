import SwiftUI

/// Send privately (NIP-17, lane D). The share sheet queues the message and,
/// optionally, a recent recipient; the review card shows who it goes to and
/// the exact text, and sends only on its button. Tron review, mandatory.
///
/// Only text goes out: a shared link or note. Files are not sent (there is no
/// NIP-17 file message in the app yet), and the card says so.
struct DMShareHandler: SharePortalHandler {
    let action = NVShareAction.dm

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(DMReviewView(intent: intent, close: close))
    }
}

extension DMShareHandler {
    enum SendError: LocalizedError {
        case accountChanged, notLoaded, empty, badRecipient
        var errorDescription: String? {
            switch self {
            case .accountChanged: return "The account changed, so nothing was sent."
            case .notLoaded: return "Messages are still loading for this account. Try again in a moment."
            case .empty: return "There's nothing to send."
            case .badRecipient: return "That isn't someone a message can go to."
            }
        }
    }

    static func account(for intent: NVShareIntent) -> String {
        let config = ConfigService.shared.config
        return intent.account ?? PostingAccount.resolve(active: config.activeAccountNpub, owner: config.ownerNpub)
    }

    /// The text the card starts from: what the sheet's form held, else the
    /// shared title and link, else the shared text.
    static func initialMessage(_ intent: NVShareIntent) -> String {
        if let m = intent.form["message"], !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return m }
        let url = NVShareClassifier.webURL(of: NVShareInput(url: intent.source.url, text: intent.source.text))
        if let url {
            let title = intent.source.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? url : "\(title)\n\(url)"
        }
        return intent.source.selection ?? intent.source.text ?? ""
    }

    /// The recipient the sheet picked, when it is a real npub.
    static func initialRecipientHex(_ intent: NVShareIntent) -> String? {
        guard let to = intent.form["to"], to.hasPrefix("npub1"), let d = Bech32.decode(to), d.hrp == "npub" else { return nil }
        return d.hexString
    }

    /// Sends as the share's account only. The DM service must have that
    /// account loaded, or the wrap would carry another key.
    @MainActor
    static func send(_ intent: NVShareIntent, message: String, toHex: String) async throws {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SendError.empty }
        guard toHex.count == 64, let data = Data(hexString: toHex), let toNpub = Bech32.encode(hrp: "npub", data: data) else { throw SendError.badRecipient }
        let npub = account(for: intent)
        guard DMShareAccountRow.isReady(npub), let hex = Bech32.decode(npub)?.hexString else { throw SendError.accountChanged }
        guard DMService.shared.loadedAccountPubkey.lowercased() == hex.lowercased() else { throw SendError.notLoaded }
        try await DMService.shared.sendDM(content: text, to: toHex)
        let profile = NostrService.shared.profiles[toHex]
        let contact = NVShareContactsSnapshot.Contact(npub: toNpub, name: profile?.bestName ?? "",
                                                      picture: profile?.pictureURL?.absoluteString)
        let current = NVShareContactsSnapshot.read() ?? NVShareContactsSnapshot()
        current.recording(contact, for: npub).keeping(accounts: Set(ConfigService.shared.allAccountNpubs)).write()
    }
}
