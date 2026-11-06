import Foundation

extension ConfigService {
    /// Writes `whitelisted_npubs.json` from the vault rule (signing accounts
    /// only, `HavenConfig.vaultWhitelistNpubs`), even when empty. When the
    /// running relay was started with a different list (a key or signer
    /// removed or added, an account removed), it restarts so the change
    /// holds now: the engine can add a key live but never drop one.
    func writeVaultWhitelist(encoder: JSONEncoder) {
        let list = config.vaultWhitelistNpubs
        if let data = try? encoder.encode(list) {
            try? data.write(to: relayDataDir.appendingPathComponent(config.whitelistedNpubsFile))
        }
        let relay = RelayProcessManager.shared
        if relay.isRunning, let running = relay.lastConfig, running.vaultWhitelistNpubs != list {
            relay.applySavedConfig(config)
        }
    }
}
