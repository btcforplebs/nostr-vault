package com.nostrvault.ui.screens.browser

import android.content.Context
import androidx.compose.ui.platform.UriHandler
import com.nostrvault.fips.FipsUrl

/**
 * Where a tapped link opens (iOS/Mac: InAppBrowser.swift). A `.fips` site always opens here over the mesh, never
 * in the system browser, which would send its npub to DNS; an http(s) page opens here while "Open Links in Nostr
 * Vault" is on (the default); any other scheme goes to the system as before.
 */
object InAppBrowser {
    /** Settings → Privacy → Open Links in Nostr Vault. */
    private const val PREFS = "in_app_browser"
    private const val OPEN_LINKS_KEY = "open_links_in_app"

    fun opensLinksInApp(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(OPEN_LINKS_KEY, true)

    fun setOpensLinksInApp(context: Context, on: Boolean) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(OPEN_LINKS_KEY, on).apply()

    /** Opens [url] in the in-app browser when the route says so. False: the caller hands it to the system. */
    fun open(context: Context, url: String): Boolean {
        val target = when (val route = FipsUrl.route(url, opensLinksInApp(context))) {
            is FipsUrl.Route.Mesh -> route.url
            is FipsUrl.Route.Web -> route.url
            // Shown as the browser's "can't open here" page, not handed on.
            FipsUrl.Route.RefusedFips -> url
            FipsUrl.Route.System -> return false
        }
        context.startActivity(InAppBrowserActivity.intent(context, target))
        return true
    }

    /**
     * The app's root [UriHandler]: every `uriHandler.openUri` (notes, bios, articles, DMs, marketplace, link
     * previews) lands here first, and only what the browser doesn't take reaches [system].
     */
    class Handler(private val context: Context, private val system: UriHandler) : UriHandler {
        override fun openUri(uri: String) {
            if (!open(context, uri)) system.openUri(uri)
        }
    }
}
