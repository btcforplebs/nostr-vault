import SwiftUI

/// "Posting as" on a share review card: which account the share signs as,
/// and a switch to it when another one is active. Lane B's cards use it;
/// HighlightReviewView has its own copy from phase 1.
struct ShareAccountSection: View {
    let npub: String
    var title = "Posting as"
    @ObservedObject private var config = ConfigService.shared

    var body: some View {
        let name = ShareAccountSection.name(npub)
        Section(title) {
            Text(name)
            if !ShareAccountSection.isOnDevice(npub) {
                Text("That account isn't on this device any more.").font(.footnote).foregroundStyle(.secondary)
            } else if !ShareAccountSection.isActive(npub) {
                Button("Switch to \(name)") { config.switchActiveAccount(to: npub) }
            }
        }
    }

    /// The account a share acts as: the one picked in the share sheet, else
    /// the one active now.
    static func account(for intent: NVShareIntent) -> String {
        let config = ConfigService.shared.config
        return intent.account ?? PostingAccount.resolve(active: config.activeAccountNpub, owner: config.ownerNpub)
    }

    static func isOnDevice(_ npub: String) -> Bool { ConfigService.shared.allAccountNpubs.contains(npub) }

    static func isActive(_ npub: String) -> Bool {
        let config = ConfigService.shared.config
        return PostingAccount.resolve(active: config.activeAccountNpub, owner: config.ownerNpub) == npub
    }

    /// Ready to sign as `npub`: on this device and the active one.
    static func canAct(as npub: String) -> Bool { isOnDevice(npub) && isActive(npub) }

    /// Locks `npub` for a publish, or nil when it can't sign now.
    static func lock(_ npub: String) -> PostingAccount.Lock? {
        guard canAct(as: npub), let hex = Bech32.decode(npub)?.hexString else { return nil }
        return PostingAccount.Lock(npub: npub, hex: hex)
    }

    static func name(_ npub: String) -> String {
        let profile = Bech32.decode(npub).flatMap { NostrService.shared.profiles[$0.hexString] }
        return profile?.bestName ?? String(npub.prefix(16)) + "…"
    }
}
