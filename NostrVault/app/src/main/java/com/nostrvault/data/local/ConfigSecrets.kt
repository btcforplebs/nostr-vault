package com.nostrvault.data.local

import com.nostrvault.relay.HavenConfig
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive

/**
 * The secrets nostrvault_config.json used to hold as plaintext: the wallet
 * connection (its URI carries the key that spends from the wallet) and each
 * account's NIP-46 signer link (bunker URI, connect secret, client key). They live in [CredentialStore] (AndroidKeyStore)
 * and stay on [HavenConfig] in memory, so no reader or writer changes:
 * [ConfigStore] fills them in at load and writes the file without each one the
 * store holds. Mirrors iOS HavenConfig+ConfigSecrets.
 *
 * Not the S3 fields: nothing on Android sets them, and the relay service reads
 * them straight from the file ([com.nostrvault.relay.RelayForegroundService.loadSavedConfig]).
 */
internal object ConfigSecrets {
    const val NWC_URI = "config-nwc-uri"
    fun bunkerURI(npub: String) = "config-nip46-bunker-uri-$npub"
    fun bunkerSecret(npub: String) = "config-nip46-secret-$npub"
    fun clientSecretKey(npub: String) = "config-nip46-client-secret-$npub"

    /** Every such secret in [cfg], by store account. Blank values are left out. */
    fun of(cfg: HavenConfig): Map<String, String> = buildMap {
        cfg.nwcURI?.takeIf { it.isNotEmpty() }?.let { put(NWC_URI, it) }
        for ((npub, b) in cfg.accountBunkerConfigs) {
            b.bunkerURI.takeIf { it.isNotEmpty() }?.let { put(bunkerURI(npub), it) }
            b.secret.takeIf { it.isNotEmpty() }?.let { put(bunkerSecret(npub), it) }
            b.clientSecretKey.takeIf { it.isNotEmpty() }?.let { put(clientSecretKey(npub), it) }
        }
    }

    /**
     * [cfg] with each blank secret filled from [stored] (the store). A value
     * the file still holds wins: only a save the store refused leaves one
     * there, so it is the current one, and the next save stores it. Every slot
     * is read, so [stored] sees all the store holds for this config.
     */
    fun attach(cfg: HavenConfig, stored: (String) -> String?): HavenConfig {
        fun pick(file: String?, account: String): String? {
            val kept = stored(account)?.takeIf { it.isNotEmpty() }
            return if (file.isNullOrEmpty()) kept ?: file else file
        }
        return cfg.copy(
            nwcURI = pick(cfg.nwcURI, NWC_URI),
            accountBunkerConfigs = cfg.accountBunkerConfigs.mapValues { (npub, b) ->
                b.copy(
                    bunkerURI = pick(b.bunkerURI, bunkerURI(npub)).orEmpty(),
                    secret = pick(b.secret, bunkerSecret(npub)).orEmpty(),
                    clientSecretKey = pick(b.clientSecretKey, clientSecretKey(npub)).orEmpty(),
                )
            },
        )
    }

    /**
     * [cfg] as the file gets it: without each secret whose account is in
     * [inStore]. One the store did not take stays, so a failed write never
     * loses it.
     */
    fun stripped(cfg: HavenConfig, inStore: Set<String>): HavenConfig {
        if (inStore.isEmpty()) return cfg
        return cfg.copy(
            nwcURI = if (NWC_URI in inStore) null else cfg.nwcURI,
            accountBunkerConfigs = cfg.accountBunkerConfigs.mapValues { (npub, b) ->
                b.copy(
                    bunkerURI = if (bunkerURI(npub) in inStore) "" else b.bunkerURI,
                    secret = if (bunkerSecret(npub) in inStore) "" else b.secret,
                    clientSecretKey = if (clientSecretKey(npub) in inStore) "" else b.clientSecretKey,
                )
            },
        )
    }

    /**
     * Removes each of [secrets] from [text] (a copy of the config, say one set
     * aside unreadable) as a whole JSON string, quotes included, replaced by
     * `""`: a short secret never matches inside other text and the copy still
     * parses. Both the escaped form and a hand-written one with plain `/`.
     */
    fun scrub(text: String, secrets: Collection<String>): String {
        var out = text
        for (secret in secrets) {
            if (secret.isEmpty()) continue
            val quoted = Json.encodeToString(JsonPrimitive.serializer(), JsonPrimitive(secret))
            for (needle in setOf(quoted, quoted.replace("\\/", "/"))) out = out.replace(needle, "\"\"")
        }
        return out
    }
}

/**
 * Keeps the store's config secrets in step with the config. [synced] is what
 * the store is known to hold: only a secret it held and the config has since
 * dropped is deleted, so a launch that could not read the store (closed,
 * see [CredentialStore.unreadable]) never empties it.
 */
internal class ConfigSecretSync(synced: Map<String, String> = emptyMap()) {
    var synced: Map<String, String> = synced
        private set

    /** Writes changed secrets, deletes dropped ones; returns the accounts the store now holds the current value for. */
    fun sync(
        current: Map<String, String>,
        store: (account: String, value: String) -> Boolean,
        delete: (account: String) -> Boolean,
    ): Set<String> {
        val now = synced.toMutableMap()
        val held = mutableSetOf<String>()
        for ((account, value) in current) {
            if (now[account] == value || store(account, value)) {
                now[account] = value
                held += account
            } else if (now[account] != null && delete(account)) {
                // The store refused the new value but still holds the old
                // one: drop it, so the file (which keeps the new one) is the only copy.
                now.remove(account)
            }
        }
        for (account in now.keys.toList()) {
            if (account !in current && delete(account)) now.remove(account)
        }
        synced = now
        return held
    }
}
