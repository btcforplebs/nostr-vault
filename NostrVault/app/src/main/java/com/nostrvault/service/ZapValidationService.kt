package com.nostrvault.service

import com.nostrvault.data.model.FeedProfile

/**
 * NIP-57 zap receipt spoofing guard.
 *
 * A kind 9735 zap receipt is just a normal Nostr event — anyone can publish one
 * claiming any amount, pointing at any note/profile, on any relay. The only thing
 * that makes a receipt trustworthy is that it was published by the pubkey the
 * recipient's own LNURL endpoint designates (`nostrPubkey` in the LNURL pay
 * response) as the one authorized to publish receipts on their behalf. Without
 * checking that, every zap total/notification in the app is spoofable by anyone
 * who can reach a relay it queries.
 */
object ZapValidationService {
    // recipientPubkey -> that recipient's authorized zap-receipt publisher, or null
    // if it couldn't be determined (no lud16, resolution failed, or the provider
    // doesn't advertise one). Cached for the app session since this rarely changes.
    private val authorizedPublisherCache = mutableMapOf<String, String?>()

    /**
     * Whether [receiptPubkey] (the actual publisher of a kind 9735 event) should be
     * trusted as a real zap on [recipientPubkey]'s behalf.
     *
     * Fails open when we can't determine the recipient's authorized publisher
     * (missing lud16, network error, or a provider that simply doesn't advertise
     * `nostrPubkey`) — that's the same trust level the app has always had, not a
     * regression. It only fails a receipt when we positively know who *should*
     * have published it and this one didn't come from them.
     */
    suspend fun isValidReceipt(
        receiptPubkey: String,
        recipientPubkey: String,
        profiles: Map<String, FeedProfile>,
    ): Boolean {
        val authorized = resolveAuthorizedPublisher(recipientPubkey, profiles) ?: return true
        return receiptPubkey.equals(authorized, ignoreCase = true)
    }

    /**
     * The pubkey [recipientPubkey]'s LNURL service names as its zap-receipt
     * publisher, or null when that can't be determined. For callers that must
     * fail closed, unlike [isValidReceipt].
     */
    suspend fun authorizedPublisher(recipientPubkey: String, profiles: Map<String, FeedProfile>): String? =
        resolveAuthorizedPublisher(recipientPubkey, profiles)

    private suspend fun resolveAuthorizedPublisher(
        recipientPubkey: String,
        profiles: Map<String, FeedProfile>,
    ): String? {
        authorizedPublisherCache[recipientPubkey]?.let { return it }
        if (authorizedPublisherCache.containsKey(recipientPubkey)) return null // cached negative

        // No profile yet is not an answer: caching null here would leave this
        // recipient unresolved for the whole session once it loads.
        val profile = profiles[recipientPubkey] ?: return null
        val resolved = try {
            when {
                !profile.lud16.isNullOrEmpty() -> LNURLService.resolveAddress(profile.lud16!!).nostrPubkey
                !profile.lud06.isNullOrEmpty() -> LNURLService.resolveRawLNURL(profile.lud06!!).nostrPubkey
                else -> null
            }
        } catch (e: Exception) {
            null
        }

        authorizedPublisherCache[recipientPubkey] = resolved
        return resolved
    }
}
