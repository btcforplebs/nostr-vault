package com.nostrvault.service.shareportal.handlers

import com.nostrvault.service.shareportal.RecipeLdParser
import com.nostrvault.service.shareportal.SharePageFetcher
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
 * Recipe pre-fill: the page's JSON-LD Recipe saved as a recipe draft for the
 * intent's account. Nothing is published. Twin: RecipeShareHandler.swift.
 */
@Singleton
class RecipeShareHandler @Inject constructor(
    private val drafts: ComposerDraftStore,
    private val fetcher: SharePageFetcher,
    private val signer: ShareSigner,
) : ShareHandler {
    override val action = ShareAction.RECIPE
    override val isReady = true

    fun url(intent: ShareIntent): String? =
        ShareClassifier.webUrl(ShareInput(url = intent.source.url, text = intent.source.text))

    /** Fetches the page and reads its recipe; title + source line only when it has none. */
    suspend fun load(intent: ShareIntent): RecipeLdParser.Recipe {
        val url = url(intent)
        val html = url?.let { fetcher.html(it) }.orEmpty()
        return RecipeLdParser.parse(html, intent.source.title, url)
    }

    fun save(intent: ShareIntent, r: RecipeLdParser.Recipe, now: Long = System.currentTimeMillis()): String? {
        val account = signer.accountHex(intent) ?: return null
        val id = ComposerDraftStore.newId()
        drafts.save(
            ComposerDraft(
                kind = ComposerDraft.Kind.RECIPE, id = id, updatedAt = now,
                title = r.title, summary = r.summary, body = r.body, prepTime = r.prepTime, cookTime = r.cookTime,
                servings = r.servings, ingredients = r.ingredients, directions = r.directions, categories = r.categories,
            ),
            cover = null, account = account,
        )
        return id
    }
}
