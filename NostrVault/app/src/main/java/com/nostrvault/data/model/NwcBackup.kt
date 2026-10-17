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

    /**
     * What the account's slot holds, as far as this device can tell. Only
     * [Status.Empty] says nothing is saved; a slot that exists but was not (or
     * could not) be read is its own state, so the screen never claims "not
     * saved" while the secret may still be on the relays. iOS `NWCBackup.Status`.
     */
    sealed class Status {
        /** No relay answered: can't say either way. */
        data object Unknown : Status()
        /**
         * A relay answered and had no wallet, or the wallet was removed. (One
         * that never answers, such as a Mac relay that is off, can't keep the
         * screen from deciding.)
         */
        data object Empty : Status()
        class Saved(val uri: String, override val savedAt: Long) : Status() {
            override fun equals(other: Any?) = other is Saved && other.uri == uri && other.savedAt == savedAt
            override fun hashCode() = uri.hashCode() * 31 + savedAt.hashCode()
            /** The wallet string is a spending secret: never in a log or crash report. */
            override fun toString() = "Saved(uri=<redacted>, savedAt=$savedAt)"
        }
        /** Saved; reading it needs the signer, which is only asked when the user taps. */
        data class NeedsSigner(override val savedAt: Long) : Status()
        /** Saved, but this device can't read it (no key, signer refused, not a wallet). */
        data class Unreadable(override val savedAt: Long) : Status()

        /** A slot with a wallet in it exists on the account, readable or not. */
        val hasSlot: Boolean get() = this is Saved || this is NeedsSigner || this is Unreadable

        /** When the slot's wallet was saved; null when there is none or it's unknown. */
        open val savedAt: Long? get() = null
    }

    /** How far the slot's content was read. */
    sealed class Read {
        /** Not tried: it would ask the signer, and the user hasn't tapped. */
        data object NotTried : Read()
        data object Failed : Read()
        class Plaintext(val text: String) : Read() {
            override fun toString() = "Plaintext(<redacted>)"
        }
    }

    /** One found slot: the newest event's content, tags and time. */
    data class Slot(val content: String, val tags: List<List<String>>, val createdAt: Long)

    /**
     * The status for a lookup: [slot] is the newest event found (null when
     * none), [answeredAny] whether at least one relay answered the request
     * (EOSE). A refusal such as `CLOSED: auth-required` is not an answer.
     */
    fun status(slot: Slot?, answeredAny: Boolean, read: Read): Status {
        if (slot == null) return if (answeredAny) Status.Empty else Status.Unknown
        if (isCleared(slot.content, slot.tags)) return Status.Empty
        return when (read) {
            Read.NotTried -> Status.NeedsSigner(slot.createdAt)
            Read.Failed -> Status.Unreadable(slot.createdAt)
            is Read.Plaintext -> walletString(read.text)?.let { Status.Saved(it, slot.createdAt) }
                ?: Status.Unreadable(slot.createdAt)
        }
    }
}
