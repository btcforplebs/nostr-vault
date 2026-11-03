package com.nostrvault.service.shareportal.handlers

import com.nostrvault.service.UserStatusPublisher
import com.nostrvault.service.shareportal.ShareSigner
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareClassifier
import com.nostrvault.shareportal.ShareInput
import com.nostrvault.shareportal.ShareIntent
import javax.inject.Inject
import javax.inject.Singleton

/** "What I'm playing" (NIP-38) from a music or video link. Twin: StatusShareHandler.swift. */
@Singleton
class StatusShareHandler @Inject constructor(private val publisher: UserStatusPublisher) : ShareHandler {
    override val action = ShareAction.STATUS
    override val isReady = true

    fun url(intent: ShareIntent): String? =
        ShareClassifier.webUrl(ShareInput(url = intent.source.url, text = intent.source.text))

    /** The status text the card starts from: the share's title, else the link. */
    fun initialText(intent: ShareIntent): String =
        intent.source.title?.trim()?.takeIf { it.isNotEmpty() } ?: url(intent).orEmpty()

    suspend fun publish(intent: ShareIntent, text: String, expirySeconds: Long, nowSeconds: Long = System.currentTimeMillis() / 1000) =
        publisher.publish(intent, text, url(intent), nowSeconds + expirySeconds)
}
