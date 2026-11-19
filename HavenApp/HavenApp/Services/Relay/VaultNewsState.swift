import Foundation

/// The Vault tab's news dot state, apart from `RelayProcessManager` so a
/// note from someone else lighting it redraws the tab button and the Vault
/// lists, not the feed. Rules in RelayProcessManager+NewsDot.
@MainActor
final class VaultNewsState: ObservableObject {
    static let shared = VaultNewsState()
    private init() {}

    /// The Vault lists that events from OTHERS landed in, via your inbox/chat
    /// relay, since you last looked at each. The Vault tab's red dot shows
    /// while any remain; the mode pill marks which.
    @Published var newActivityModes: Set<VaultMode> = []
    var hasNewRelayActivity: Bool { !newActivityModes.isEmpty }
    /// Unread DMs the Vault Dashboard has already shown: the tab's dot
    /// lights for more than this (VaultNewsDot).
    @Published var dmUnreadSeen = 0
}
