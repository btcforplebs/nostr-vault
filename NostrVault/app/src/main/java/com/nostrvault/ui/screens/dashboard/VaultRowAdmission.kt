package com.nostrvault.ui.screens.dashboard

import com.nostrvault.data.model.VaultActivity

/**
 * The checks every relay-half row passes, from the live subscription, the
 * store read or a page of older history. Older pages skipped them, so a
 * forged zap receipt showed in Zaps and its totals and a post with a future
 * clock jumped to the top (Vault tab review 2026-11-27, finding 3).
 *
 * - A wrong clock dated it ahead: it would top the pages ([VaultActivity.isFuture]).
 * - NIP-57: a zap receipt is spoofable by anyone who can reach a relay we
 *   query. Only trust it if it came from the pubkey the recipient's own LNURL
 *   endpoint names as its publisher ([validReceipt]).
 */
internal suspend fun vaultRowAdmitted(
    kind: Int,
    pubkey: String,
    createdAt: Long,
    tags: List<List<String>>,
    now: Long,
    validReceipt: suspend (receiptPubkey: String, recipientPubkey: String) -> Boolean,
): Boolean {
    if (VaultActivity.isFuture(createdAt, now)) return false
    if (kind == 9735) {
        val recipient = tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: return false
        if (!validReceipt(pubkey, recipient)) return false
    }
    return true
}
