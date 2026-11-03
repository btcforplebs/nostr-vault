import SwiftUI

/// "Posting as" on a Share Portal review card: who the share is for, and a
/// switch when that is not the active account. `isReady` is true only when
/// the account is on this device and active, which is when signing is safe.
struct SharePortalAccountSection: View {
    let intent: NVShareIntent
    var title = "Posting as"
    @ObservedObject private var config = ConfigService.shared

    static func isReady(_ intent: NVShareIntent) -> Bool {
        let config = ConfigService.shared
        let npub = SharePortalPosting.account(for: intent)
        let active = PostingAccount.resolve(active: config.config.activeAccountNpub, owner: config.config.ownerNpub)
        return config.allAccountNpubs.contains(npub) && npub == active
    }

    var body: some View {
        let npub = SharePortalPosting.account(for: intent)
        let name = Self.name(npub)
        let active = PostingAccount.resolve(active: config.config.activeAccountNpub, owner: config.config.ownerNpub)
        Section(title) {
            Text(name)
            if !config.allAccountNpubs.contains(npub) {
                Text("That account isn't on this device any more.").font(.footnote).foregroundStyle(.secondary)
            } else if npub != active {
                Button("Switch to \(name)") { config.switchActiveAccount(to: npub) }
            }
        }
    }

    static func name(_ npub: String) -> String {
        let profile = Bech32.decode(npub).flatMap { NostrService.shared.profiles[$0.hexString] }
        return profile?.bestName ?? String(npub.prefix(16)) + "…"
    }
}

/// The Publish / Save row at the bottom of a review card.
struct SharePortalActionButton: View {
    let title: String
    let busy: Bool
    let enabled: Bool
    var footer: String?
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                HStack {
                    Spacer()
                    if busy { ProgressView() } else { Text(title).font(.headline) }
                    Spacer()
                }
            }
            .disabled(!enabled || busy)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}
