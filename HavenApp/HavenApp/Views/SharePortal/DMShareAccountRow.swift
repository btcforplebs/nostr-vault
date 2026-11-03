import SwiftUI

/// "Sending as" on the Pay and Send privately review cards: the share's
/// account, and a switch when it is not the active one. Both actions refuse
/// to run as any other account.
struct DMShareAccountRow: View {
    let npub: String
    let title: String

    @ObservedObject private var config = ConfigService.shared

    var isReady: Bool { Self.isReady(npub) }

    static func isReady(_ npub: String) -> Bool {
        let c = ConfigService.shared
        return c.allAccountNpubs.contains(npub)
            && PostingAccount.resolve(active: c.config.activeAccountNpub, owner: c.config.ownerNpub) == npub
    }

    var body: some View {
        let name = Self.name(npub)
        Section(title) {
            Text(name)
            if !config.allAccountNpubs.contains(npub) {
                Text("That account isn't on this device any more.").font(.footnote).foregroundStyle(.secondary)
            } else if !isReady {
                Button("Switch to \(name)") { config.switchActiveAccount(to: npub) }
            }
        }
    }

    static func name(_ npub: String) -> String {
        let profile = Bech32.decode(npub).flatMap { NostrService.shared.profiles[$0.hexString] }
        return profile?.bestName ?? String(npub.prefix(16)) + "…"
    }
}
