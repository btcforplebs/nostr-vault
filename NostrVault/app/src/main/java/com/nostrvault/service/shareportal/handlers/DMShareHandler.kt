package com.nostrvault.service.shareportal.handlers

import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareClassifier
import com.nostrvault.shareportal.ShareInput
import com.nostrvault.shareportal.ShareIntent

/**
 * Send privately (NIP-17, lane D). The review card
 * ([com.nostrvault.ui.screens.shareportal.DMReviewViewModel]) picks the
 * recipient and sends; this says the action is ready and what text the card
 * starts from. Only text goes out: there is no NIP-17 file message yet, and
 * the card says so. Twin: DMShareHandler.swift.
 */
object DMShareHandler : ShareHandler {
    override val action = ShareAction.DM
    override val isReady = true

    /** The sheet's message, else the shared title and link, else the shared text. */
    fun initialMessage(intent: ShareIntent): String {
        intent.form["message"]?.takeIf { it.isNotBlank() }?.let { return it }
        val url = ShareClassifier.webUrl(ShareInput(url = intent.source.url, text = intent.source.text))
        if (url != null) {
            val title = intent.source.title?.trim().orEmpty()
            return if (title.isEmpty()) url else "$title\n$url"
        }
        return intent.source.selection ?: intent.source.text.orEmpty()
    }

    /** The recipient the sheet suggested, when it looks like an npub. */
    fun initialRecipientNpub(intent: ShareIntent): String? =
        intent.form["to"]?.takeIf { it.startsWith("npub1") && it.length == 63 }
}
