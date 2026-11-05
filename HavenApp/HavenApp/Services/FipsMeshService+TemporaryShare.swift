#if os(iOS)
import Foundation
import UIKit

/// Sharing that isn't the owner's kiosk mode: kiosk mode (own devices in
/// full, strangers at the mesh door) for a while, never brought back by
/// itself and never posting the paused note.
/// - a just-linked device's copy (`shareForCopy`, OtherVaultCopy.shareWindow);
/// - while the app is open with a phone linked (`shareWhileOpenIfWanted`),
///   so that phone's new notes and media reach this one (Logen 2026-11-05).
extension FipsMeshService {
    /// This iPhone was A in a link: share the vault with its own devices for
    /// `OtherVaultCopy.shareWindow`, so the device it just linked can copy
    /// from it ("Copy from my other vault"). Off again after the window or
    /// when the app leaves the screen. Nothing if it already shares.
    /// Returns whether it is sharing for the copy.
    @discardableResult
    func shareForCopy() -> Bool {
        // Already sharing while the app is open: that covers the copy.
        if sharingWhileOpen, kioskActive || starting { return true }
        guard OtherVaultCopy.sharesAfterLink(wasA: true, meshOn: FipsMeshSettings.enabled,
                                             alreadySharing: kioskActive || starting) else { return false }
        startKiosk()
        guard starting || kioskActive else { return false }
        copyShareUntil = Date().addingTimeInterval(TimeInterval(OtherVaultCopy.shareWindow))
        copyShareTimer?.invalidate()
        copyShareTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(OtherVaultCopy.shareWindow),
                                              repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.copyShareUntil != nil else { return }
                print("FipsMesh: copy window over, kiosk mode off")
                self.stopKiosk()
            }
        }
        print("FipsMesh: sharing for a linked device's copy, \(OtherVaultCopy.shareWindow / 60) min")
        return true
    }

    /// While the app is open, an iPhone with a linked phone shares its vault
    /// with its own devices, so their new notes and media reach it
    /// (HomeVaultSender's phone lanes; Logen 2026-11-05). Off when the app
    /// leaves the screen; the screen may sleep, and no paused note.
    func shareWhileOpenIfWanted() {
        let own = ownMeshNpub ?? Self.meshNpubFromKey()
        let phones = HomeVaultLogic.phoneTargets(devices: FipsMeshDevices.current(ConfigService.shared.config),
                                                 ownNpub: own, homeVault: nil, mac: nil)
        guard HomeVaultLogic.sharesWhileOpen(meshOn: FipsMeshSettings.enabled,
                                             appActive: UIApplication.shared.applicationState == .active,
                                             alreadySharing: kioskActive || starting,
                                             linkedPhones: phones.count) else { return }
        sharingWhileOpen = true
        startKiosk()
        if !starting && !kioskActive {
            sharingWhileOpen = false
            return
        }
        print("FipsMesh: sharing with My Devices while the app is open (\(phones.count) linked phone(s))")
    }

    func clearTemporaryShare() {
        copyShareTimer?.invalidate()
        copyShareTimer = nil
        copyShareUntil = nil
        sharingWhileOpen = false
    }

    func endTemporaryShareKeepingKiosk() {
        clearTemporaryShare()
        UserDefaults.standard.set(true, forKey: Self.kioskWantedKey)
        if kioskActive { UIApplication.shared.isIdleTimerDisabled = true }
    }
}
#endif
