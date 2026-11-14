import SwiftUI

/// The Vault list changes once per refresh, not once per batch (Logen
/// 2026-11-13: "I see new followers first, then everything else gets injected
/// after"). While a read is on, the list on screen stays and the new one goes
/// up when the read is done. Once the store read answered (VaultDirectRead),
/// only it counts as reading. Rules in VaultListSwap and VaultDirectRead.
extension VaultView {
    /// Whether the Vault list just built for `owner` from `eventCount` events
    /// goes on screen now. Main actor; call right before publishing.
    func listSwapPublishes(owner: String, eventCount: Int) -> Bool {
        // Nothing read yet counts as reading: followers come from disk before
        // the first read answers, and must not show alone.
        let refreshing = VaultDirectRead.reading(
            storeAnswered: nostrService.vaultStoreAnswered == owner.lowercased(),
            storeReading: nostrService.vaultStoreReading,
            socketReading: nostrService.isFetching,
            booting: relayManager.isBooting,
            nothingYet: eventCount == 0 && !activityHasLoadedOnce)
        if !refreshing {
            listHeldSince = nil
        } else if listHeldSince == nil {
            listHeldSince = Date()
            // Look again once the cap is up, in case the read never ends.
            DispatchQueue.main.asyncAfter(deadline: .now() + VaultListSwap.cap + 0.1) {
                scheduleUpdateDisplayData()
            }
        }
        let held = listHeldSince.map { Date().timeIntervalSince($0) }
        guard VaultListSwap.publishes(refreshing: refreshing, heldFor: held) else { return false }
        return true
    }

    /// An account switch: the old account's lines go; the store read for the
    /// new one (NostrService.handleAccountSwitch) is the next thing to show.
    func listSwapAccountSwitched() {
        displayActivity = []
        activityHasLoadedOnce = false
        listHeldSince = nil
    }

    /// A read started or ended: build again; the swap above decides whether
    /// it goes on screen.
    func listSwapReadChanged() {
        scheduleUpdateDisplayData()
    }
}
