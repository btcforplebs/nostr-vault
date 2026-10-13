import Foundation

/// The owner's bunker session while another account is active.
///
/// The local relay's AUTH is signed as the owner through the owner's own
/// signer session (`NIP46SignEventWithC`). At launch only the active account's
/// signer is logged in, so with another account active the owner had no
/// session after a restart: /chat AUTH failed and no DMs arrived. This logs
/// the owner in beside it (`NIP46ConnectBackgroundC`), never making it the
/// active signer, then lets DM retry the AUTH it could not sign.
extension NIP46Service {
    /// A background owner login in flight, so a burst of AUTH challenges or
    /// switches starts only one.
    private static var ownerLoginInFlight = false

    /// Logs the owner's bunker in without making it active, when the owner
    /// signs with a bunker and another account is active. A session that is
    /// already live is left alone. On success the DM /chat AUTH is retried.
    func connectOwnerInBackgroundIfNeeded() {
        let config = ConfigService.shared.config
        guard config.ownerNeedsBackgroundSession, !Self.ownerLoginInFlight,
              let link = config.ownerBunkerLink,
              let clientSK = config.accountBunkerConfigs[config.ownerNpub]?.clientSecretKey,
              !clientSK.isEmpty else { return }
        let ownerHex = Bech32.decode(config.ownerNpub)?.hexString ?? ""
        Self.ownerLoginInFlight = true
        Task {
            // Blocking in Go (the signer has to answer): off the main actor.
            let pubkey: String? = await Task.detached {
                guard let cStr = NIP46ConnectBackgroundC(
                    UnsafeMutablePointer(mutating: (clientSK as NSString).utf8String),
                    UnsafeMutablePointer(mutating: (link as NSString).utf8String)
                ) else { return nil as String? }
                defer { free(cStr) }
                return String(cString: cStr)
            }.value
            Self.ownerLoginInFlight = false
            // A session answering for another account is not dropped here: two
            // accounts on one signer share its session, and dropping it would
            // log the active account out.
            guard let pubkey, !ownerHex.isEmpty, pubkey == ownerHex else {
                RelayProcessManager.shared.addLog("NIP-46: Owner's signer not connected in the background", level: "ERROR")
                return
            }
            RelayProcessManager.shared.addLog("NIP-46: Owner's signer connected in the background", level: "INFO")
            DMService.shared.retryPendingAuth()
        }
    }
}
