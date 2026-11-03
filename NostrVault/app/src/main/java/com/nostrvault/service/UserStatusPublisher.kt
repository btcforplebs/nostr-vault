package com.nostrvault.service

import com.nostrvault.service.shareportal.ShareSigner
import com.nostrvault.shareportal.ShareIntent
import javax.inject.Inject
import javax.inject.Singleton

/**
 * NIP-38 user status (kind 30315), "what I'm playing", from a shared music or
 * video link. Public and short-lived: it carries an expiration. Twin:
 * UserStatusPublisher.swift.
 */
@Singleton
class UserStatusPublisher @Inject constructor(private val signer: ShareSigner) {
    suspend fun publish(intent: ShareIntent, text: String, url: String?, expiresAt: Long): ShareSigner.Outcome {
        val tags = tags(text, url, expiresAt)
        return signer.send(intent) { lock ->
            signEventAsync(kind = 30315, content = text.trim(), tags = tags, lockedTo = lock)
        }
    }

    companion object {
        const val KIND = 30315
        /** The card's expiry choices, in seconds; the middle one is the default. */
        val EXPIRY_CHOICES = listOf(30 * 60L, 60 * 60L, 4 * 60 * 60L)
        const val DEFAULT_EXPIRY = 60 * 60L

        fun tags(text: String, url: String?, expiresAt: Long): List<List<String>> = buildList {
            add(listOf("d", "music"))
            url?.takeIf { it.isNotEmpty() }?.let { add(listOf("r", it)) }
            add(listOf("expiration", expiresAt.toString()))
            add(listOf("alt", "Status: ${text.trim()}"))
        }
    }
}
