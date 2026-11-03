package com.nostrvault.service.shareportal.handlers

import com.nostrvault.service.LabelPublisher
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareClassifier
import com.nostrvault.shareportal.ShareInput
import com.nostrvault.shareportal.ShareIntent
import javax.inject.Inject
import javax.inject.Singleton

/** Flag a link (NIP-32) with one of Nostr Vault's fixed labels. Twin: LabelShareHandler.swift. */
@Singleton
class LabelShareHandler @Inject constructor(private val publisher: LabelPublisher) : ShareHandler {
    override val action = ShareAction.LABEL
    override val isReady = true

    fun url(intent: ShareIntent): String? =
        ShareClassifier.webUrl(ShareInput(url = intent.source.url, text = intent.source.text))

    suspend fun publish(intent: ShareIntent, label: String, comment: String) =
        url(intent)?.let { publisher.publish(intent, label, it, comment) }
}
