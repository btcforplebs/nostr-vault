import Combine
import Foundation

/// The Vault tab's news dot state, apart from `RelayProcessManager` so a
/// note from someone else lighting it redraws the tab button and the Vault
/// lists, not the feed. Rules in RelayProcessManager+NewsDot.
@MainActor
final class VaultNewsState: ObservableObject {
    static let shared = VaultNewsState()
    private var cancellable: AnyCancellable?

    private init() {
        // The active account's saved count, at launch and on every switch,
        // before anything reads the dot for the new account.
        cancellable = ConfigService.shared.$activeAccountHexPubkey
            .removeDuplicates()
            .sink { [weak self] account in self?.load(account: account) }
    }

    /// The account `dmUnreadSeen` belongs to.
    private var account = ""

    /// The Vault lists that events from OTHERS landed in, via your inbox/chat
    /// relay, since you last looked at each. The Vault tab's red dot shows
    /// while any remain; the mode pill marks which.
    @Published var newActivityModes: Set<VaultMode> = []
    var hasNewRelayActivity: Bool { !newActivityModes.isEmpty }
    /// Unread DMs the Vault Dashboard has already shown: the tab's dot
    /// lights for more than this (VaultNewsDot).
    @Published var dmUnreadSeen = 0 {
        didSet { if dmUnreadSeen != oldValue { VaultNewsDot.saveSeen(dmUnreadSeen, account: account) } }
    }

    private func load(account next: String) {
        account = next.lowercased()
        let saved = VaultNewsDot.savedSeen(account: account)
        if dmUnreadSeen != saved { dmUnreadSeen = saved }
    }
}
