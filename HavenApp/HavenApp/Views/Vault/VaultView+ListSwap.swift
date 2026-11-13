import SwiftUI

/// The Vault list changes once per refresh, not once per batch (Logen
/// 2026-11-13: "I see new followers first, then everything else gets injected
/// after"). While a read is on, the list on screen stays and the new one goes
/// up when the read is done; a saved screen (VaultSnapshotStore) goes up at
/// once. Rules in VaultListSwap.
extension VaultView {
    /// Whether the Vault list just built for `owner` from `eventCount` events
    /// goes on screen now. Main actor; call right before publishing.
    func listSwapPublishes(owner: String, eventCount: Int) -> Bool {
        // Nothing read yet counts as reading: followers come from disk before
        // the first socket answers, and must not show alone.
        let refreshing = nostrService.isFetching || relayManager.isBooting
            || (eventCount == 0 && !activityHasLoadedOnce)
        if !refreshing {
            listHeldSince = nil
        } else if listHeldSince == nil {
            listHeldSince = Date()
            // Look again once the cap is up, in case the read never ends.
            DispatchQueue.main.asyncAfter(deadline: .now() + VaultListSwap.cap + 0.1) {
                scheduleUpdateDisplayData()
            }
        }
        let savedScreen = showsSavedScreen && eventCount > 0
            && VaultSnapshotStore.restoredAccount == owner.lowercased()
        let held = listHeldSince.map { Date().timeIntervalSince($0) }
        guard VaultListSwap.publishes(force: savedScreen, refreshing: refreshing, heldFor: held) else { return false }
        if savedScreen { showsSavedScreen = false }
        return true
    }

    /// An account switch: the old account's lines go, its saved screen (if
    /// any) is the next thing to show.
    func listSwapAccountSwitched() {
        displayActivity = []
        activityHasLoadedOnce = false
        listHeldSince = nil
        showsSavedScreen = true
    }

    /// A read ended: put the list built meanwhile on screen.
    func listSwapReadChanged() {
        if !(nostrService.isFetching || relayManager.isBooting) { scheduleUpdateDisplayData() }
    }
}
