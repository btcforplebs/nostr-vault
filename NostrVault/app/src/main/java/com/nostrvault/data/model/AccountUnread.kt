package com.nostrvault.data.model

/**
 * Each account's new notifications since its Vault list was last viewed: the
 * number on that account's row in the account switcher.
 *
 * The vault serves every account on the device, and each NOTIFY marker names
 * the account it is for (`recipient=<hex>`, haven-go import.go
 * emitInboxNotify). Markers are counted by event id, so a marker raised twice
 * counts once. Viewing an account's Vault list empties its count, the same
 * moment that list moves its own seen mark (`vaultActivitySeenAt.<hex>`).
 * iOS: AccountUnread.swift.
 *
 * @property ids account hex to unseen event ids, oldest first
 */
data class AccountUnread(val ids: Map<String, List<String>> = emptyMap()) {

    fun count(hex: String): Int = ids[hex.lowercase()]?.size ?: 0

    /** With the marker [body] (the text after `🔔NOTIFY|`) counted; this same value when it does not count. */
    fun record(body: String): AccountUnread {
        val (recipient, id) = parse(body) ?: return this
        val list = ids[recipient].orEmpty()
        if (id in list) return this
        return copy(ids = ids + (recipient to (list + id).takeLast(CAP)))
    }

    /** The account's Vault list was viewed. */
    fun markSeen(hex: String): AccountUnread {
        val key = hex.lowercase()
        return if (key in ids) copy(ids = ids - key) else this
    }

    companion object {
        /** Ids kept per account. The badge reads "99+" long before this. */
        const val CAP = 200

        /**
         * The marker types that become lines in the Vault list. DMs are read
         * and cleared in Messages, and the catch-up summary names no account.
         */
        val COUNTED_TYPES = setOf("reply", "quote", "mention", "reaction", "repost", "zap", "follow")

        private val HEX64 = Regex("^[0-9a-f]{64}$")

        /** The account and event a marker body is for, or null when it does not count. */
        fun parse(body: String): Pair<String, String>? {
            // The preview is last and may hold "|" or "=": cut it off first.
            val p = body.indexOf("|preview=")
            val head = if (p >= 0) body.substring(0, p) else body
            val fields = head.split('|').mapNotNull { part ->
                val eq = part.indexOf('=')
                if (eq < 0) null else part.substring(0, eq) to part.substring(eq + 1)
            }.toMap()
            val type = fields["type"] ?: return null
            if (type !in COUNTED_TYPES) return null
            val recipient = fields["recipient"]?.lowercase() ?: return null
            if (!HEX64.matches(recipient)) return null
            val id = fields["id"]?.takeIf { it.isNotEmpty() } ?: return null
            return recipient to id
        }

        /** The badge text: null at zero, "99+" past 99. */
        fun badge(count: Int): String? = when {
            count <= 0 -> null
            count > 99 -> "99+"
            else -> count.toString()
        }
    }
}
