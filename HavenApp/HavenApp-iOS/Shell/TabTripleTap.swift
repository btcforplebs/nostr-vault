import SwiftUI

/// What a triple-tap on a tab-bar button does (Logen, 2026-11-19). The
/// second tap of the run has already done the re-tap job (back to the list,
/// up to the top); the third goes home.
@MainActor
enum TabTripleTap {
    /// Feed: the Following feed, at its top.
    static func feed(_ feedService: FeedService) {
        // switchMode also asks the new feed to open at its top.
        if feedService.feedMode != .following { feedService.switchMode(.following) }
        NotificationCenter.default.post(name: NSNotification.Name("ScrollToTop"), object: nil)
    }

    /// Vault: its main page (the Vault list, not Media, Emoji, Messages or
    /// another list), at its top.
    static func vault() {
        VaultMode.activity.select()
        // Once the Vault list has swapped in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: NSNotification.Name("RelayScrollToTop"), object: nil)
        }
    }
}
