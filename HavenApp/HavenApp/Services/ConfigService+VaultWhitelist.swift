import Foundation

extension ConfigService {
    /// Writes `whitelisted_npubs.json` (every account,
    /// `HavenConfig.vaultWhitelistNpubs`) and `private_reader_npubs.json`
    /// (accounts with a key or signer here, `vaultPrivateReaderNpubs`), even
    /// when empty. When the running relay was started with a different list
    /// (an account, key or signer added or removed), it restarts so the
    /// change holds now: the engine can add a key live but never drop one.
    func writeVaultWhitelist(encoder: JSONEncoder) {
        let list = config.vaultWhitelistNpubs
        let readers = config.vaultPrivateReaderNpubs
        HavenConfig.writeVaultAccountFiles(whitelist: list, readers: readers, whitelistFile: config.whitelistedNpubsFile,
                                           under: relayDataDir, encoder: encoder)
        let relay = RelayProcessManager.shared
        if relay.isRunning, let running = relay.lastConfig,
           running.vaultWhitelistNpubs != list || running.vaultPrivateReaderNpubs != readers {
            relay.applySavedConfig(config)
        }
    }
}
