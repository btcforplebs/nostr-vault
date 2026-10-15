package com.nostrvault.data.model

/**
 * What the Vault's search makes of the notes the local relay matched (iOS
 * `VaultSearchLogic.swift`): which kind of result each one is, the hashtags and
 * links they carry, who a pasted key names, and which query the results on
 * screen are for. Pure, so it is tested on its own.
 */
object VaultSearchLogic {

    /** The Vault's result sections, in the order they show. */
    enum class Section(val title: String) {
        PEOPLE("People"), NOTES("Notes"), ARTICLES("Articles"), MEDIA("Media"), HASHTAGS("Hashtags"), LINKS("Links")
    }

    const val ARTICLE_KIND = 30023
    /** NIP-68 pictures, NIP-71 videos (normal and short), and the older addressable video kinds. */
    val MEDIA_KINDS: Set<Int> = setOf(20, 21, 22, 34235, 34236)

    /**
     * Notes, articles, highlights, comments, polls and media: the kinds the
     * Vault's lists show, without reposts (their content is the reposted event's
     * JSON), plus media. iOS `VaultSearchModel.noteKinds`.
     */
    val NOTE_KINDS: List<Int> = VaultMode.RELAY_TAB_NOTE_KINDS.filter { it != 6 }.sorted() + MEDIA_KINDS.sorted()

    /** Which section a matched note belongs in. Everything not an article or media is a note. */
    fun section(kind: Int): Section = when (kind) {
        ARTICLE_KIND -> Section.ARTICLES
        in MEDIA_KINDS -> Section.MEDIA
        else -> Section.NOTES
    }

    // (?U): `\w` as Unicode word characters, like NSRegularExpression, so #日本 and #café are tags.
    private val hashtagRegex = Regex("(?U)#(\\w+)")

    /**
     * Hashtags on the matched notes that contain any word of the query, from the
     * text (`#word`) and from `t` tags, lowercased, deduplicated and sorted. `#`
     * in the query is ignored, so "#bitcoin" and "bitcoin" find the same tags.
     */
    fun hashtags(contents: List<Pair<String, List<List<String>>>>, query: String): List<String> {
        val words = query.lowercase().replace("#", " ").split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return emptyList()
        val found = HashSet<String>()
        for ((content, tags) in contents) {
            val all = hashtagsInText(content) +
                tags.filter { it.size >= 2 && it[0] == "t" && it[1].isNotEmpty() }.map { it[1].lowercase() }
            for (tag in all) if (words.any { tag.contains(it) }) found += tag
        }
        return found.sorted()
    }

    /** `#word` hashtags in a note's text, lowercased, without the `#`. */
    fun hashtagsInText(text: String): List<String> =
        hashtagRegex.findAll(text).map { it.groupValues[1].lowercase() }.toList()

    data class Link(
        val url: String,
        /** The URL without its scheme, for the row's title. */
        val title: String,
        val noteId: String,
    )

    private val urlRegex = Regex("https?://[^\\s]+")

    /**
     * Links in the matched notes, each URL once, in note order. A note that
     * matched on its text gives its links even when the query is not in the URL,
     * as the Search tab does. Trailing punctuation that closes a sentence is not
     * part of the link; a closing bracket the URL itself opened is
     * (`…/wiki/Foo_(bar)`).
     */
    fun links(notes: List<Pair<String, String>>): List<Link> {
        val seen = HashSet<String>()
        val links = ArrayList<Link>()
        for ((id, content) in notes) {
            for (match in urlRegex.findAll(content)) {
                val url = trimmingTrailingPunctuation(match.value)
                if (!seen.add(url)) continue
                links += Link(url, url.replace("https://", "").replace("http://", ""), id)
            }
        }
        return links
    }

    private val openers = mapOf(')' to '(', ']' to '[')

    /**
     * Strips what closes the sentence around a URL. `)` and `]` go only when the
     * URL has more closers than openers, so "(see https://x.y/a)" loses its paren
     * and "https://en.wikipedia.org/wiki/Foo_(bar)" keeps it.
     */
    fun trimmingTrailingPunctuation(raw: String): String {
        var url = raw
        while (url.isNotEmpty()) {
            val last = url.last()
            val open = openers[last]
            url = when {
                last in ".,;:!?\"'" -> url.dropLast(1)
                open != null && url.count { it == last } > url.count { it == open } -> url.dropLast(1)
                else -> return url
            }
        }
        return url
    }

    // ── People ──

    private fun bareKey(query: String): String {
        val text = query.trim().lowercase()
        return if (text.startsWith("nostr:")) text.drop(6) else text
    }

    /**
     * The public key a query names: 64 hex characters, or an `npub1…` that
     * [decodeNpub] accepts (a good checksum), with or without `nostr:`.
     * Lowercased hex.
     */
    fun pubkey(query: String, decodeNpub: (String) -> String?): String? {
        val text = bareKey(query)
        if (text.length == 64 && text.all { it in '0'..'9' || it in 'a'..'f' }) return text
        if (text.startsWith("npub1")) return decodeNpub(text)?.lowercase()?.takeIf { it.length == 64 }
        return null
    }

    /**
     * The key to show a bare People row for when the walk found nobody. An npub
     * is unambiguously a key. Bare hex may be a note id (also 64 hex), so it
     * counts only when a store already holds that profile; otherwise the row
     * would be a person who does not exist.
     */
    fun keyOnlyPerson(query: String, decodeNpub: (String) -> String?, hasProfile: (String) -> Boolean): String? {
        val key = pubkey(query, decodeNpub) ?: return null
        return if (bareKey(query).startsWith("npub1") || hasProfile(key)) key else null
    }

    /**
     * Whether a profile the relay walk matched belongs under People. A query
     * that is a key finds that one person. Any other query has to be in the
     * names, about or NIP-05: the walk also matches it inside the hex key, so
     * "ab" or "cafe" would otherwise list nearly everyone.
     */
    fun keepsPerson(pubkey: String, fields: List<String?>, query: String, decodeNpub: (String) -> String?): Boolean {
        pubkey(query, decodeNpub)?.let { return pubkey.lowercase() == it }
        val matcher = SearchTermMatcher.create(query) ?: return false
        val lowered = fields.filterNotNull().map { it.lowercase() }
        return matcher.terms.all { term -> lowered.any { it.contains(term) } }
    }

    // ── Query state ──

    /** How the Vault's search stands. */
    enum class Status {
        /** Nothing typed, or under two characters. */
        IDLE,
        SEARCHING,
        /** The relay walk finished. */
        DONE,
        /** The walk hit its deadline: the results are real, but what it had not reached is missing. */
        CUT_SHORT,
        /** The Vault's relay was not up, so only what the app had already loaded was searched. */
        IN_MEMORY,
    }

    /**
     * Which query is on screen and which one the results are for. A search that
     * lands is kept only if it is for the query in the field now: comparing with
     * the last results' query instead left the spinner up for good (type "ab",
     * then "abc", then back to "ab", and "abc" landed for nothing).
     */
    class QueryState {
        sealed interface Next {
            /** Under two characters: drop the results and any search running. */
            data object Clear : Next
            /** The results on screen are already for this query: stop any search and show them. */
            data object Keep : Next
            /** Search this query. */
            data class Run(val query: String) : Next
        }

        var live = ""
            private set
        var resultsQuery = ""
            private set
        var status = Status.IDLE
            private set
        /** How the search behind the results on screen ended. */
        private var resultsStatus = Status.IDLE

        /** The field changed. */
        fun typed(query: String): Next {
            val trimmed = query.trim()
            live = trimmed
            if (trimmed.length < 2) {
                resultsQuery = ""
                status = Status.IDLE
                resultsStatus = Status.IDLE
                return Next.Clear
            }
            // An in-memory or cut-short answer is worth asking again for: the
            // relay may be up now, or answer faster.
            if (trimmed == resultsQuery && resultsStatus == Status.DONE) {
                status = Status.DONE
                return Next.Keep
            }
            return Next.Run(trimmed)
        }

        /** A search for [query] starts. False if the field has moved on. */
        fun started(query: String): Boolean {
            if (query != live) return false
            status = Status.SEARCHING
            return true
        }

        /** A search for [query] came back. False, and nothing changes, if the field no longer holds it. */
        fun landed(query: String, result: Status): Boolean {
            if (query != live) return false
            resultsQuery = query
            status = result
            resultsStatus = result
            return true
        }

        fun reset() {
            live = ""
            resultsQuery = ""
            status = Status.IDLE
            resultsStatus = Status.IDLE
        }
    }
}
