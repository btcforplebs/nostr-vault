package com.nostrvault.shareportal

/** One file the share surface was handed, as far as the classifier cares. */
data class ShareInputFile(val mime: String, val name: String)

/** Everything another app shared, before anyone picked an action. */
data class ShareInput(
    val url: String? = null,
    val title: String? = null,
    val text: String? = null,
    val selection: String? = null,
    val files: List<ShareInputFile> = emptyList(),
    val ldTypes: List<String> = emptyList(),
)

/**
 * What a share most likely wants done, most likely first, no duplicates.
 *
 * Pure. Mirrors NVShareClassifier.swift; the rules are
 * docs/SHARE_PORTAL_CONTRACT.md §3 and Fixtures/SharePortal/classifier-cases.json
 * is the test for both platforms. Phase 2 lanes ask the phase-1 builder for a
 * change here rather than editing it.
 */
object ShareClassifier {

    fun classify(input: ShareInput): List<ShareAction> {
        val web = webUrl(input)
        val haystack = listOfNotNull(input.url, input.text, input.selection).joinToString("\n")
        val media = input.files.any { isMedia(it) }
        val out = LinkedHashSet<ShareAction>()
        fun add(vararg actions: ShareAction) { out.addAll(actions) }

        if (isPay(haystack, input.text)) add(ShareAction.PAY)
        if (PROFILE.containsMatchIn(haystack)) add(ShareAction.PROFILE)
        if (input.files.any { isCalendar(it) } || "Event" in input.ldTypes) add(ShareAction.CALENDAR)
        if (!input.selection.isNullOrBlank()) add(ShareAction.HIGHLIGHT)
        if (media) add(ShareAction.UPLOAD, ShareAction.MEDIA_POST)
        if (input.files.any { isPdf(it) }) add(ShareAction.PRIVATE_COPY)
        if ("Recipe" in input.ldTypes) add(ShareAction.RECIPE)
        if (web != null && isMusicHost(web)) add(ShareAction.STATUS)
        if (web != null) {
            add(ShareAction.BOOKMARK, ShareAction.ARTICLE_CLIP, ShareAction.HIGHLIGHT,
                ShareAction.PRIVATE_COPY, ShareAction.DM, ShareAction.LABEL)
        } else if (!input.text.isNullOrBlank()) {
            add(ShareAction.HIGHLIGHT, ShareAction.DM)
        }
        if (input.files.any { !isMedia(it) }) add(ShareAction.DM)
        return out.toList()
    }

    /** `url` when it is http(s), else the first http(s) run in `text`. */
    fun webUrl(input: ShareInput): String? {
        input.url?.trim()?.takeIf { WEB_PREFIX.containsMatchIn(it) }?.let { return it }
        return input.text?.let { WEB_IN_TEXT.find(it)?.value }
    }

    /** The URL's host, lowercased, without userinfo or port; null if it has none. */
    fun host(url: String): String? {
        val afterScheme = url.substringAfter("://", missingDelimiterValue = "").ifEmpty { return null }
        val authority = afterScheme.takeWhile { it != '/' && it != '?' && it != '#' }
        val host = authority.substringAfterLast('@').substringBefore(':').lowercase()
        return host.ifEmpty { null }
    }

    private fun isPay(haystack: String, text: String?): Boolean {
        if (BOLT11.containsMatchIn(haystack) || LNURL.containsMatchIn(haystack)) return true
        val t = text?.trim() ?: return false
        return LN_ADDRESS.matches(t)
    }

    private fun isMusicHost(url: String): Boolean {
        var h = host(url) ?: return false
        h = when {
            h.startsWith("www.") -> h.removePrefix("www.")
            h.startsWith("m.") -> h.removePrefix("m.")
            else -> h
        }
        return h in MUSIC_HOSTS || h.endsWith(".bandcamp.com")
    }

    private fun isMedia(f: ShareInputFile): Boolean {
        val m = f.mime.lowercase()
        return m.startsWith("image/") || m.startsWith("video/")
    }

    private fun isPdf(f: ShareInputFile) =
        f.mime.equals("application/pdf", ignoreCase = true) || f.name.lowercase().endsWith(".pdf")

    private fun isCalendar(f: ShareInputFile) =
        f.mime.equals("text/calendar", ignoreCase = true) || f.name.lowercase().endsWith(".ics")

    private const val BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    private val WEB_PREFIX = Regex("^https?://", RegexOption.IGNORE_CASE)
    private val WEB_IN_TEXT = Regex("https?://[^\\s<>\"]+", RegexOption.IGNORE_CASE)
    // A bolt11 carries its amount digits and the `1` separator, so the run
    // after the prefix is [0-9a-z], not the strict bech32 alphabet.
    private val BOLT11 = Regex("(?<![0-9a-z])(?:lightning:)?ln(?:bcrt|bc|tbs|tb)[0-9a-z]{20,}", RegexOption.IGNORE_CASE)
    private val LNURL = Regex("(?<![0-9a-z])(?:lightning:)?lnurl1[0-9a-z]{20,}", RegexOption.IGNORE_CASE)
    private val LN_ADDRESS = Regex("^(?:lightning:)?[a-z0-9._-]+@[a-z0-9.-]+\\.[a-z]{2,}$", RegexOption.IGNORE_CASE)
    private val PROFILE = Regex("npub1[$BECH32]{58}|nprofile1[$BECH32]{20,}", RegexOption.IGNORE_CASE)
    private val MUSIC_HOSTS = setOf(
        "open.spotify.com", "music.apple.com", "youtube.com", "youtu.be", "music.youtube.com",
        "soundcloud.com", "tidal.com", "wavlake.com", "fountain.fm",
    )
}
