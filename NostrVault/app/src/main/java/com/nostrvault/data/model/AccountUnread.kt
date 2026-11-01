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

    /**
     * Whether an account other than [active] has news: the dot on the bottom
     * bar's avatar. Only [accounts] (the hex keys still signed in) are asked,
     * so a removed account's leftover ids can't hold the dot up with no row
     * left to clear them. iOS: othersHaveUnread(accounts:active:).
     */
    fun othersHaveUnread(accounts: Collection<String>, active: String): Boolean {
        val a = active.lowercase()
        return accounts.any { it.lowercase() != a && count(it) > 0 }
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
        fun parse(body: String): Pair<String, String>? =
            parseMarker(body)?.let { it.recipient to it.id }

        /**
         * Whether the Vault list draws a marker's event, by the same rules
         * VaultActivity.build and the list screen use: nobody blocked, no
         * replies, quotes or mentions from outside your network, and no
         * reactions in Zaps Only. Without this the switcher read "5 new" over
         * a list with nothing new in it (sweep 11-01 #11).
         */
        fun listShows(
            marker: Marker,
            zapsOnly: Boolean,
            isBlocked: (String) -> Boolean,
            isOutside: (String) -> Boolean,
        ): Boolean {
            val author = marker.author
            if (author.isNotEmpty() && isBlocked(author)) return false
            return when (marker.type) {
                "reaction" -> !zapsOnly
                "reply", "quote", "mention" -> author.isEmpty() || !isOutside(author)
                else -> true
            }
        }

        /** A marker's fields, or null when it does not count. */
        fun parseMarker(body: String): Marker? {
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
            return Marker(type, fields["author"].orEmpty().lowercase(), recipient, id)
        }

        /**
         * One of your accounts tagging another (A tags B) while "Notify me
         * when my own accounts tag each other" is off: no Vault line, no
         * count, no dot and no alert. An account tagging itself is not this;
         * the relay already keeps that quiet. [accounts] holds every account
         * on the device, by hex. iOS: NotificationPolicy.hidesOwnAccountTag.
         */
        fun hidesOwnAccountTag(author: String, recipient: String, accounts: Set<String>, notify: Boolean): Boolean {
            if (notify) return false
            val a = author.lowercase()
            val r = recipient.lowercase()
            if (a.isEmpty() || r.isEmpty() || a == r) return false
            val mine = accounts.mapTo(HashSet()) { it.lowercase() }
            return a in mine && r in mine
        }

        /**
         * The inbox kinds in a batch of NOTIFY markers that came in only as one
         * of your accounts tagging another ([isOwnAccountTag] of recipient,
         * author), so the Vault tab's dot can leave them out the way the list
         * does. A kind that also came from anyone else stays. iOS:
         * AccountUnread.ownAccountOnlyKinds.
         */
        fun ownAccountOnlyKinds(markers: List<String>, isOwnAccountTag: (String, String) -> Boolean): Set<Int> {
            val own = HashSet<Int>()
            val other = HashSet<Int>()
            for (raw in markers) {
                val m = raw.indexOf(MARKER_PREFIX)
                val body = if (m >= 0) raw.substring(m + MARKER_PREFIX.length) else raw
                val p = body.indexOf("|preview=")
                val head = if (p >= 0) body.substring(0, p) else body
                val fields = head.split('|').mapNotNull { part ->
                    val eq = part.indexOf('=')
                    if (eq < 0) null else part.substring(0, eq) to part.substring(eq + 1)
                }.toMap()
                val kind = fields["kind"]?.toIntOrNull() ?: continue
                val recipient = fields["recipient"].orEmpty().lowercase()
                val author = fields["author"].orEmpty().lowercase()
                if (isOwnAccountTag(recipient, author)) own += kind else other += kind
            }
            return own - other
        }

        private const val MARKER_PREFIX = "NOTIFY|"

        /** The badge text: null at zero, "99+" past 99. */
        fun badge(count: Int): String? = when {
            count <= 0 -> null
            count > 99 -> "99+"
            else -> count.toString()
        }
    }

    /** One counted NOTIFY marker. [author] is the zap's sender for zaps (haven-go inboxTrustKey). */
    data class Marker(val type: String, val author: String, val recipient: String, val id: String)
}
