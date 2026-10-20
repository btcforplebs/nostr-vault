package com.nostrvault.ui.components

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.model.VaultNoteScope
import com.nostrvault.relay.HavenBridge

/**
 * "Open in …" links out to the rest of Nostr: the web app that does each kind
 * of post best, named by naddr or nprofile so it fetches the same event we
 * show. One table, so every screen and both platforms send a kind to the same
 * place (Logen, 10/20):
 *
 * - recipes → zap.cooking
 * - live streams → zap.stream
 * - long-form articles → YakiHonne (actively kept up; Habla has gone quiet)
 * - people, and the WoT trust card → Brainstorm, so trust can be checked
 *   off the device
 */
object NostrWebLinks {
    /** A place to open, and the menu words for it. */
    data class WebLink(val label: String, val url: String)

    private const val ARTICLE_KIND = VaultNoteScope.ARTICLE_KIND

    /**
     * Where an addressable post opens on the web, or null for a kind no site
     * here shows, or an event with no `d` tag to address it by.
     */
    fun forEvent(kind: Int, authorPubkey: String, tags: List<List<String>>): WebLink? {
        if (kind != ARTICLE_KIND && kind != LiveStream.KIND) return null
        val d = tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: return null
        val naddr = HavenBridge.encodeNaddr(d, authorPubkey, kind) ?: return null
        return when {
            kind == LiveStream.KIND -> WebLink("Open in zap.stream", "https://zap.stream/$naddr")
            VaultNoteScope.isRecipe(tags) -> WebLink("Open in zap.cooking", "https://zap.cooking/recipe/$naddr")
            else -> WebLink("Open in YakiHonne", "https://yakihonne.com/article/$naddr")
        }
    }

    /** A live stream, by the address its chat and naddr are built from. */
    fun forStream(stream: LiveStream): WebLink? =
        HavenBridge.encodeNaddr(stream.identifier, stream.authorPubkey, LiveStream.KIND)
            ?.let { WebLink("Open in zap.stream", "https://zap.stream/$it") }

    /** A person on Brainstorm, whose /p/ page takes an nprofile. */
    fun forProfile(pubkey: String): WebLink? =
        HavenBridge.encodeNprofile(pubkey)
            ?.let { WebLink("Open in Brainstorm", "https://brainstorm.world/p/$it") }

    /**
     * Opens [url] in the system browser. A browser selector, so an installed
     * Nostr app that claims these hosts doesn't catch the link; any app that
     * views it if no browser is set up.
     */
    fun open(context: Context, url: String) {
        val uri = Uri.parse(url)
        val view = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val browser = Intent(view).apply {
            selector = Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_BROWSER)
        }
        try {
            context.startActivity(browser)
        } catch (_: ActivityNotFoundException) {
            try { context.startActivity(view) } catch (_: ActivityNotFoundException) { }
        }
    }
}
