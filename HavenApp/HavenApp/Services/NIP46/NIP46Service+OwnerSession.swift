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
    /// The background owner login's state (`OwnerSessionWarmup`): one at a time.
    private static var ownerWarmup = OwnerSessionWarmup()

    /// Logs the owner's bunker in without making it active, when
    /// `OwnerSessionWarmup.start` says so. A session that is already live is
    /// left alone. Called on account switch and whenever an owner-forced AUTH
    /// (DM /chat, drafts /private, the Vault counts) could not be signed; on
    /// success the DM /chat AUTH is retried, the others on their next run.
    func connectOwnerInBackgroundIfNeeded() {
        let config = ConfigService.shared.config
        let ownerHex = Bech32.decode(config.ownerNpub)?.hexString ?? ""
        guard let login = Self.ownerWarmup.start(config: config, ownerHex: ownerHex) else { return }
        Task {
            // Blocking in Go (the signer has to answer): off the main actor.
            let pubkey: String? = await Task.detached {
                guard let cStr = NIP46ConnectBackgroundC(
                    UnsafeMutablePointer(mutating: (login.clientSecretKey as NSString).utf8String),
                    UnsafeMutablePointer(mutating: (login.link as NSString).utf8String)
                ) else { return nil as String? }
                defer { free(cStr) }
                return String(cString: cStr)
            }.value
            guard Self.ownerWarmup.finished(login, pubkey: pubkey) else {
                RelayProcessManager.shared.addLog("NIP-46: Owner's signer not connected in the background", level: "ERROR")
                return
            }
            RelayProcessManager.shared.addLog("NIP-46: Owner's signer connected in the background", level: "INFO")
            DMService.shared.retryPendingAuth()
        }
    }
}
