package com.nostrvault.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.util.LruCache
import coil.compose.AsyncImage
import com.nostrvault.ui.theme.*
import androidx.core.text.HtmlCompat
import com.nostrvault.util.UrlSafety
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/**
 * OpenGraph link preview card shown below note content, one per non-media URL.
 *
 * The URL itself is no longer in the note text (#170 parity), so this card is
 * the only trace of the link: while the page loads, and when it has no
 * OpenGraph data or cannot be reached, a domain-only card still opens it.
 *
 * Fetches OG metadata (title, description, image, siteName) via HTML meta tags.
 * Layout: 72dp image | title (13sp bold, 2 lines) + description (12sp, 2 lines) + domain (10sp).
 * Cached in a companion-level map to avoid repeated fetches.
 */
@Composable
fun LinkPreviewCard(
    url: String,
    modifier: Modifier = Modifier,
) {
    // A Wavlake song plays right here instead of opening a web page.
    com.nostrvault.data.music.WavlakeLink.trackId(url)?.let { trackId ->
        com.nostrvault.ui.screens.music.WavlakeTrackCard(trackId, modifier)
        return
    }
    val colors = LocalNostrVaultColors.current
    val uriHandler = LocalUriHandler.current
    var metadata by remember(url) { mutableStateOf(ogMetadataCache.get(url)) }
    var fetched by remember(url) { mutableStateOf(ogMetadataCache.get(url) != null) }

    // Fetch OG metadata on first composition
    LaunchedEffect(url) {
        if (!fetched) {
            fetched = true
            val result = fetchOgMetadata(url)
            ogMetadataCache.put(url, result)
            metadata = result
        }
    }

    val meta = metadata
    if (meta == null || (meta.title.isNullOrBlank() && meta.description.isNullOrBlank() && meta.imageUrl.isNullOrBlank())) {
        LinkFallbackCard(url, modifier)
        return
    }

    Surface(
        shape = RoundedCornerShape(8.dp),
        color = TertiaryGroupedBg,
        border = BorderStroke(
            // Embedded in a note, so it tracks NoteCard's OLED bump
            // rather than sitting fainter than the card it lives inside.
            if (LocalOledMode.current) 0.8.dp else 0.5.dp,
            colors.primary.copy(alpha = if (LocalOledMode.current) 0.18f else 0.12f),
        ),
        modifier = modifier
            .fillMaxWidth()
            .clickable {
                try { uriHandler.openUri(url) } catch (_: Exception) {}
            },
    ) {
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier.padding(10.dp),
        ) {
            // Image thumbnail
            if (!meta.imageUrl.isNullOrBlank()) {
                AsyncImage(
                    model = meta.imageUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(72.dp)
                        .clip(RoundedCornerShape(6.dp)),
                )
                Spacer(Modifier.width(10.dp))
            }

            Column(modifier = Modifier.weight(1f)) {
                // Title
                if (!meta.title.isNullOrBlank()) {
                    Text(
                        text = meta.title!!,
                        color = PrimaryText,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        lineHeight = 17.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                // Description
                if (!meta.description.isNullOrBlank()) {
                    if (!meta.title.isNullOrBlank()) Spacer(Modifier.height(2.dp))
                    Text(
                        text = meta.description!!,
                        color = SecondaryText,
                        fontSize = 12.sp,
                        lineHeight = 16.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                // Domain
                Spacer(Modifier.height(2.dp))
                Text(
                    text = meta.siteName ?: extractDomain(url),
                    color = TertiaryText,
                    fontSize = 10.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** Link icon, the domain, an ↗ arrow: the link with nothing fetched about it. */
@Composable
fun LinkFallbackCard(
    url: String,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val uriHandler = LocalUriHandler.current
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = TertiaryGroupedBg,
        border = BorderStroke(
            if (LocalOledMode.current) 0.8.dp else 0.5.dp,
            colors.primary.copy(alpha = if (LocalOledMode.current) 0.18f else 0.12f),
        ),
        modifier = modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) { contentDescription = "Link to ${linkDomain(url)}" }
            .clickable {
                try { uriHandler.openUri(url) } catch (_: Exception) {}
            },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            Icon(
                imageVector = NostrVaultIcons.LinkIcon,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = linkDomain(url),
                color = PrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(text = "↗", color = TertiaryText, fontSize = 13.sp)
        }
    }
}

// ── OG Metadata ──────────────────────────────────────────────────

data class OgMetadata(
    val title: String?,
    val description: String?,
    val imageUrl: String?,
    val siteName: String?,
)

/**
 * Bounded in-memory cache for OG metadata. LruCache is internally synchronized and
 * size-capped, replacing an unbounded HashMap that grew one entry per distinct link
 * ever scrolled past (and was written concurrently from composition coroutines).
 */
private val ogMetadataCache = LruCache<String, OgMetadata>(200)

/** The host a link points at, without `www.`, for cards and chips. */
fun linkDomain(url: String): String = extractDomain(url)

private fun extractDomain(url: String): String {
    return try {
        URL(url).host.removePrefix("www.")
    } catch (_: Exception) {
        url.removePrefix("https://").removePrefix("http://").substringBefore("/")
    }
}

/**
 * Fetch OpenGraph metadata from a URL by parsing HTML meta tags.
 * Returns an OgMetadata with whatever could be extracted.
 */
private const val MAX_OG_REDIRECTS = 5

private suspend fun fetchOgMetadata(url: String): OgMetadata = withContext(Dispatchers.IO) {
    val empty = OgMetadata(null, null, null, null)
    try {
        // SSRF guard: never fetch internal/private hosts (the app runs a local
        // relay/Blossom/bridge on localhost). Follow redirects manually so each
        // hop is re-validated — auto-follow could bounce a public URL to 127.0.0.1.
        var current = url
        var connection: HttpURLConnection? = null
        var hops = 0
        while (true) {
            if (!UrlSafety.isSafeRemoteUrl(current)) return@withContext empty
            val conn = (URL(current).openConnection() as HttpURLConnection).apply {
                setRequestProperty("User-Agent", "NostrVault/1.0")
                connectTimeout = 5000
                readTimeout = 5000
                instanceFollowRedirects = false
            }
            val code = conn.responseCode
            if (code in 300..399) {
                val location = conn.getHeaderField("Location")
                conn.disconnect()
                if (location == null || ++hops > MAX_OG_REDIRECTS) return@withContext empty
                // Resolve relative redirects against the current URL.
                current = try { URL(URL(current), location).toString() } catch (_: Exception) { return@withContext empty }
                continue
            }
            connection = conn
            break
        }

        val activeConn = connection ?: return@withContext empty
        val html = activeConn.inputStream.bufferedReader().use { reader ->
            val sb = StringBuilder()
            val buf = CharArray(4096)
            var total = 0
            while (total < 32_768) { // Read max 32KB
                val n = reader.read(buf)
                if (n < 0) break
                sb.append(buf, 0, n)
                total += n
                // Stop early if we've passed </head>
                if (sb.contains("</head>", ignoreCase = true)) break
            }
            sb.toString()
        }
        activeConn.disconnect()

        val title = decodeEntities(
            extractMetaContent(html, "og:title")
                ?: extractMetaContent(html, "twitter:title")
                ?: extractHtmlTitle(html)
        )
        val description = decodeEntities(
            extractMetaContent(html, "og:description")
                ?: extractMetaContent(html, "twitter:description")
        )
        val rawImageUrl = extractMetaContent(html, "og:image")
            ?: extractMetaContent(html, "twitter:image")
        // Guard the image URL too — it is handed to Coil, a second internal-fetch vector.
        val imageUrl = rawImageUrl?.takeIf { UrlSafety.isSafeRemoteUrl(it) }
        val siteName = decodeEntities(extractMetaContent(html, "og:site_name"))

        OgMetadata(title, description, imageUrl, siteName)
    } catch (_: Exception) {
        empty
    }
}

/**
 * Decode the HTML character references in an OpenGraph value.
 *
 * OpenGraph values are HTML attribute contents, so they arrive encoded
 * ("Bob&#39;s blog"). The platform parser handles both named and numeric forms,
 * so there is no table to keep. It also collapses whitespace and drops any
 * stray markup, which is what a one-line preview wants anyway. Blank after
 * decoding is treated as absent rather than shown as an empty line.
 */
private fun decodeEntities(value: String?): String? {
    if (value.isNullOrBlank()) return null
    return HtmlCompat.fromHtml(value, HtmlCompat.FROM_HTML_MODE_LEGACY)
        .toString()
        .trim()
        .takeIf { it.isNotEmpty() }
}

private val META_REGEX = Regex(
    """<meta[^>]*(?:property|name)=["']([^"']+)["'][^>]*content=["']([^"']+)["']""",
    setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
)
private val META_REGEX_REVERSE = Regex(
    """<meta[^>]*content=["']([^"']+)["'][^>]*(?:property|name)=["']([^"']+)["']""",
    setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
)
private val TITLE_REGEX = Regex(
    """<title[^>]*>([^<]+)</title>""",
    RegexOption.IGNORE_CASE,
)

private fun extractMetaContent(html: String, property: String): String? {
    for (match in META_REGEX.findAll(html)) {
        if (match.groupValues[1].equals(property, ignoreCase = true)) {
            return match.groupValues[2].trim().takeIf { it.isNotBlank() }
        }
    }
    for (match in META_REGEX_REVERSE.findAll(html)) {
        if (match.groupValues[2].equals(property, ignoreCase = true)) {
            return match.groupValues[1].trim().takeIf { it.isNotBlank() }
        }
    }
    return null
}

private fun extractHtmlTitle(html: String): String? {
    return TITLE_REGEX.find(html)?.groupValues?.get(1)?.trim()?.takeIf { it.isNotBlank() }
}
