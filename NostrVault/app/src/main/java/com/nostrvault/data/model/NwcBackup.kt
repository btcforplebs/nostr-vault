package com.nostrvault.data.model

/**
 * The wallet connection (NWC string) kept on the user's own Nostr account, so
 * another device or another app signed in with the same key can use it.
 *
 * One NIP-78 app-data event (kind 30078) in Wisp's format, so the two apps
 * read each other's: `d` = `nwc-wallet-backup`, content = the raw
 * `nostr+walletconnect://` string NIP-44 encrypted to the account's own key.
 * An empty content (and our `deleted` tag) means the saved wallet was taken
 * off. iOS twin: `NWCBackup`.
 */
object NwcBackup {
    const val KIND = 30078
    const val D_TAG = "nwc-wallet-backup"
    private const val SCHEME = "nostr+walletconnect://"

    /** Tags of a saved wallet. The content goes in already encrypted. */
    val TAGS: List<List<String>> = listOf(
        listOf("d", D_TAG),
        listOf("client", "Nostr Vault"),
        listOf("encryption", "nip44"),
    )

    /** Tags of the event that takes the saved wallet off (empty content). */
    val CLEARED_TAGS: List<List<String>> = listOf(
        listOf("d", D_TAG),
        listOf("deleted", "true"),
    )

    /** Whether an event is this account's saved-wallet slot. */
    fun isBackup(kind: Int, tags: List<List<String>>): Boolean =
        kind == KIND && tags.any { it.size >= 2 && it[0] == "d" && it[1] == D_TAG }

    /** Whether the slot holds no wallet: empty content, or marked deleted. */
    fun isCleared(content: String, tags: List<List<String>>): Boolean =
        content.isBlank() || tags.any { it.size >= 2 && it[0] == "deleted" && it[1] == "true" }

    /**
     * The wallet string in a decrypted slot, or null when it is not one. Same
     * rule as Wisp's `decryptNwcBackup`: trimmed, and it must start with
     * `nostr+walletconnect://` in any case.
     */
    fun walletString(decrypted: String): String? {
        val trimmed = decrypted.trim()
        return if (trimmed.startsWith(SCHEME, ignoreCase = true)) trimmed else null
    }

    /** The string that goes into the encrypted content: trimmed, as Wisp writes it. */
    fun plaintextForSaving(uri: String): String? = walletString(uri)

    /** True only for something that can be published: never the wallet string itself. */
    fun isCiphertext(content: String): Boolean =
        content.isNotBlank() && !content.contains("walletconnect", ignoreCase = true)
}
