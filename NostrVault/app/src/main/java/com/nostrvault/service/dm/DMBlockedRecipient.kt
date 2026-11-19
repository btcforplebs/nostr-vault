package com.nostrvault.service

/**
 * Sending to someone you blocked (B3, NV_MESSAGES_UX_CHECK 2026-11-18): the
 * send went through and the inbox then hid the chat. It now stops before
 * anything is signed, with words the "Failed to Send" alert can show.
 */
class DMBlockedRecipientException : Exception(MESSAGE) {
    companion object {
        const val MESSAGE = "You blocked this person. Unblock them to message them."
    }
}

/** True when [pubkey] is blocked by the active account. */
fun DMService.isBlocked(pubkey: String): Boolean = pubkey.lowercase() in blockedHex()

/** The active account's blocked people, as hex keys (New Message leaves them out). */
fun DMService.blockedPubkeys(): Set<String> = blockedHex()
