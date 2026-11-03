package com.nostrvault.service

import com.nostrvault.service.shareportal.ShareSigner
import com.nostrvault.shareportal.ShareIntent
import javax.inject.Inject
import javax.inject.Singleton

/**
 * NIP-32 label (kind 1985) on a web link, in Nostr Vault's own namespace with
 * a fixed set of labels (Logen's pick). Public, and about someone else's site.
 * Abuse reports stay NIP-56 (1984). Twin: LabelPublisher.swift.
 */
@Singleton
class LabelPublisher @Inject constructor(private val signer: ShareSigner) {
    suspend fun publish(intent: ShareIntent, label: String, url: String, comment: String): ShareSigner.Outcome {
        require(label in LABELS) { "Unknown label" }
        val tags = tags(label, url)
        return signer.send(intent) { lock ->
            signEventAsync(kind = 1985, content = comment.trim(), tags = tags, lockedTo = lock)
        }
    }

    companion object {
        const val KIND = 1985
        const val NAMESPACE = "app.nostrvault.link"
        val LABELS = listOf("spam", "scam", "nsfw", "good")

        fun tags(label: String, url: String): List<List<String>> = listOf(
            listOf("L", NAMESPACE),
            listOf("l", label, NAMESPACE),
            listOf("r", url),
            listOf("alt", "Label: $label for $url"),
        )
    }
}
