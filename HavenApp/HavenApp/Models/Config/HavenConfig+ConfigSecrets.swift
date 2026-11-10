import Foundation

/// The other secrets config.json used to hold as plaintext: the wallet
/// connection (its URI carries the key that spends from the wallet), the
/// backup bucket's credentials, and each NIP-46 signer link (its bunker URI
/// and connect secret). Like the NIP-46 client keys (HavenConfig+Secrets)
/// they live in the keychain (CredentialStore) and stay on `HavenConfig` in
/// memory, so every reader and writer is unchanged: ConfigService syncs them
/// to the keychain on save, fills them back in on load, and leaves out of
/// config.json each one the keychain holds.
extension HavenConfig {
    static let nwcURIAccount = "config-nwc-uri"
    static let s3AccessKeyIdAccount = "config-s3-access-key-id"
    static let s3SecretKeyAccount = "config-s3-secret-key"
    static let nip46BunkerURIAccount = "config-nip46-bunker-uri"
    static let nip46SecretAccount = "config-nip46-secret"

    static func nip46BunkerURIAccount(forNpub npub: String) -> String {
        "config-nip46-bunker-uri-\(npub)"
    }

    static func nip46SecretAccount(forNpub npub: String) -> String {
        "config-nip46-secret-\(npub)"
    }

    /// The flat secret fields, by keychain account.
    private static let flatSecretFields: [(account: String, field: WritableKeyPath<HavenConfig, String>)] = [
        (nwcURIAccount, \.nwcURI),
        (s3AccessKeyIdAccount, \.s3AccessKeyId),
        (s3SecretKeyAccount, \.s3SecretKey),
        (nip46BunkerURIAccount, \.nip46BunkerURI),
        (nip46SecretAccount, \.nip46Secret),
    ]

    /// The per-account secret fields, by keychain account.
    private static let accountSecretFields: [(account: (String) -> String, field: WritableKeyPath<AccountBunkerConfig, String>)] = [
        (nip46BunkerURIAccount(forNpub:), \.bunkerURI),
        (nip46SecretAccount(forNpub:), \.secret),
    ]

    /// Every such secret in this config, by keychain account. Empty values
    /// are left out.
    var configSecrets: [String: String] {
        var out: [String: String] = [:]
        for (account, field) in Self.flatSecretFields where !self[keyPath: field].isEmpty {
            out[account] = self[keyPath: field]
        }
        for (npub, cfg) in accountBunkerConfigs {
            for (account, field) in Self.accountSecretFields where !cfg[keyPath: field].isEmpty {
                out[account(npub)] = cfg[keyPath: field]
            }
        }
        return out
    }

    /// Fills in each secret config.json left blank from `stored` (the
    /// keychain). A value the file holds wins: it was written by a build that
    /// could not use the keychain, so it is the newer one (a wallet
    /// reconnected on an older build), and the next save stores it. Every
    /// slot is read, filled or not, so the caller learns all the keychain
    /// holds for this config.
    mutating func attachConfigSecrets(_ stored: (String) -> String?) {
        for (account, field) in Self.flatSecretFields {
            if let value = stored(account), !value.isEmpty, self[keyPath: field].isEmpty {
                self[keyPath: field] = value
            }
        }
        for npub in accountBunkerConfigs.keys {
            for (account, field) in Self.accountSecretFields {
                if let value = stored(account(npub)), !value.isEmpty,
                   accountBunkerConfigs[npub]?[keyPath: field].isEmpty == true {
                    accountBunkerConfigs[npub]?[keyPath: field] = value
                }
            }
        }
    }

    /// The config as written to disk: without each secret whose keychain
    /// account is in `inKeychain`. A secret the keychain did not take stays
    /// in the file, so a failed keychain write never loses it.
    func withoutConfigSecrets(inKeychain: Set<String>) -> HavenConfig {
        var copy = self
        for (account, field) in Self.flatSecretFields where inKeychain.contains(account) {
            copy[keyPath: field] = ""
        }
        for npub in copy.accountBunkerConfigs.keys {
            for (account, field) in Self.accountSecretFields where inKeychain.contains(account(npub)) {
                copy.accountBunkerConfigs[npub]?[keyPath: field] = ""
            }
        }
        return copy
    }

    /// What to look for in a copy of config.json to scrub `secrets`: each
    /// value as a whole JSON string, quotes included, so a short secret
    /// never matches inside other text (the encrypted key, say). Both as
    /// JSONEncoder writes it (a URI's `/` comes out as `\/`) and unescaped.
    /// Replace each with `emptyJSONString` so the copy still decodes.
    static func scrubNeedles(for secrets: [String]) -> [String] {
        var out: [String] = []
        for secret in secrets where !secret.isEmpty {
            guard let data = try? JSONEncoder().encode([secret]),
                  let json = String(data: data, encoding: .utf8) else { continue }
            let quoted = String(json.dropFirst().dropLast())  // ["…"]
            out.append(quoted)
            let plain = quoted.replacingOccurrences(of: "\\/", with: "/")
            if plain != quoted { out.append(plain) }
        }
        return out
    }

    static let emptyJSONString = "\"\""
}
