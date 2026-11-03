package com.nostrvault.service.shareportal.handlers

import com.nostrvault.service.shareportal.ArticleClipDraft
import com.nostrvault.service.shareportal.ShareSigner
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareClassifier
import com.nostrvault.shareportal.ShareInput
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.screens.ComposerDraft
import com.nostrvault.ui.screens.ComposerDraftStore
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Article clip: quote + link saved as an article draft for the intent's
 * account. Nothing is published. Twin: ArticleClipShareHandler.swift.
 */
@Singleton
class ArticleClipShareHandler @Inject constructor(
    private val drafts: ComposerDraftStore,
    private val signer: ShareSigner,
) : ShareHandler {
    override val action = ShareAction.ARTICLE_CLIP
    override val isReady = true

    fun clip(intent: ShareIntent): ArticleClipDraft.Clip = ArticleClipDraft.clip(
        intent.source.title,
        ShareClassifier.webUrl(ShareInput(url = intent.source.url, text = intent.source.text)),
        intent.source.selection,
    )

    /** Saves the draft; false when the account isn't on this device. */
    fun save(intent: ShareIntent, title: String, body: String, now: Long = System.currentTimeMillis()): String? {
        val account = signer.accountHex(intent) ?: return null
        val id = ComposerDraftStore.newId()
        drafts.save(
            ComposerDraft(kind = ComposerDraft.Kind.ARTICLE, id = id, updatedAt = now,
                title = title.trim(), body = body.trim()),
            cover = null, account = account,
        )
        return id
    }
}
