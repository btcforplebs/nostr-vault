import SwiftUI
import Combine

/// Keeps a profile page's three loaders alive without observing them. Held
/// as the page's `@StateObject`, it never publishes, so a loader changing
/// redraws only `ProfileContent` (which observes each one), not the page
/// that owns it and every sheet and toolbar item hung on it.
@MainActor
final class ProfileLoaders: ObservableObject {
    let loader: ProfileFeedLoader
    let shop = SellerListingsLoader()
    let extras = ProfileExtrasLoader()

    init(pubkey: String, usesOwnLedger: Bool) {
        loader = ProfileFeedLoader(pubkey: pubkey, usesOwnLedger: usesOwnLedger)
    }
}

/// Redraws for one profile's own metadata and nothing else. `NostrService`
/// publishes its whole `profiles` dictionary each time any author arrives,
/// and the notes being scrolled fetch their authors, so observing it redrew
/// the page several times a second mid-scroll.
@MainActor
final class ProfileMetadataWatch: ObservableObject {
    private var cancellable: AnyCancellable?
    private var pubkey: String?

    func watch(_ pubkey: String) {
        guard pubkey != self.pubkey else { return }
        self.pubkey = pubkey
        // dropFirst: the page has already drawn the current value.
        cancellable = NostrService.shared.$profiles
            .map { $0[pubkey] }
            .removeDuplicates()
            .dropFirst()
            // @Published sends before it stores; redraw once it has.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
