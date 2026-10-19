package com.nostrvault.ui.screens

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GatedArticle
import com.nostrvault.data.model.GatedArticleTeaser
import com.nostrvault.service.GatedArticleService
import com.nostrvault.ui.theme.*
import dev.jeziellago.compose.markdowntext.MarkdownText

/** What the reader of a gated article sees. iOS GatedArticleBody, minus the pay button. */
internal sealed interface GatedPhase {
    data object Checking : GatedPhase
    data object Locked : GatedPhase
    data class Unlocked(val markdown: String) : GatedPhase
    data class Failed(val message: String) : GatedPhase
}

/** Where to read or buy the article outside the app: the author's own link, else the naddr on njump. */
internal fun gatedWebUrl(note: FeedNote, gated: GatedArticle, service: GatedArticleService): String? {
    GatedArticleTeaser.unlockUrl(note.content)?.let { return it }
    val identifier = note.tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: return null
    return service.naddr(note, gated, identifier)?.let { "https://njump.me/$it" }
}

internal fun gatedStatusText(phase: GatedPhase, authorName: String, priceSats: Int): String = when (phase) {
    is GatedPhase.Failed -> phase.message
    else -> "Locked by $authorName for $priceSats sats. Paid on the web or in another app? " +
        "Tap Already paid? to read it here."
}

/**
 * The teaser and a lock card until the key server says this reader has paid,
 * then the decrypted article. Never pays: a zap made on the web or in another
 * client opens it here, since the key server only checks the zap receipt.
 */
@Composable
internal fun GatedArticleBody(
    note: FeedNote,
    gated: GatedArticle,
    service: GatedArticleService,
    author: FeedProfile?,
    bodyStyle: TextStyle,
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var phase by remember(note.id) { mutableStateOf<GatedPhase>(GatedPhase.Checking) }

    // auto: the check that runs on open. It asks the signer only when that is
    // silent (a local key); a remote signer would prompt on every view.
    suspend fun check(auto: Boolean) {
        if (auto && !service.canCheckSilently) {
            phase = GatedPhase.Locked
            return
        }
        phase = GatedPhase.Checking
        phase = try {
            GatedPhase.Unlocked(service.open(note, gated))
        } catch (e: GatedArticleService.UnlockError) {
            // Not paid yet is the normal case on open. On a check the reader
            // asked for, say why it didn't open.
            if (auto) GatedPhase.Locked else GatedPhase.Failed(e.message.orEmpty())
        } catch (e: Exception) {
            GatedPhase.Locked
        }
    }
    LaunchedEffect(note.id, service.activeReader) { check(auto = true) }

    val current = phase
    if (current is GatedPhase.Unlocked) {
        MarkdownText(
            markdown = current.markdown,
            style = bodyStyle,
            linkColor = colors.primary,
            modifier = Modifier.fillMaxWidth(),
        )
        return
    }

    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        val teaser = GatedArticleTeaser.strip(note.content)
        val summary = com.nostrvault.data.model.ArticleMeta.from(note).summary
        if (teaser.isNotEmpty() && teaser != summary) {
            MarkdownText(markdown = teaser, style = bodyStyle, linkColor = colors.primary, modifier = Modifier.fillMaxWidth())
        }
        Surface(
            shape = RoundedCornerShape(14.dp),
            color = SecondaryGroupedBg,
            border = BorderStroke(1.dp, colors.primary.copy(alpha = 0.35f)),
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.Lock, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(18.dp))
                    Text("Locked article", color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f))
                    Surface(shape = RoundedCornerShape(50), color = colors.primary.copy(alpha = 0.15f)) {
                        Text("${gated.priceSats} sats", color = colors.primary, fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp))
                    }
                }
                Text(
                    text = if (current == GatedPhase.Checking) "Checking…"
                    else gatedStatusText(current, author?.bestName ?: "the author", gated.priceSats),
                    color = SecondaryText,
                    fontSize = 14.sp,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (current == GatedPhase.Checking) {
                        CircularProgressIndicator(color = colors.primary, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                    } else {
                        TextButton(onClick = { scope.launch { check(auto = false) } }) {
                            Icon(Icons.Outlined.CheckCircle, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("Already paid?", fontSize = 13.sp)
                        }
                    }
                    gatedWebUrl(note, gated, service)?.let { url ->
                        TextButton(onClick = {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        }) {
                            Icon(Icons.Outlined.OpenInNew, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("Open on ${Uri.parse(url).host ?: "the web"}", fontSize = 13.sp)
                        }
                    }
                }
            }
        }
    }
}
