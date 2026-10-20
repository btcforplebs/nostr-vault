package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GatedArticle
import com.nostrvault.service.GatedArticleService
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** What the reader of a Fanfares article sees. iOS GatedArticleBody's phases (before #812). */
internal sealed interface GatedPhase {
    data object Checking : GatedPhase
    data object Locked : GatedPhase
    data object Paying : GatedPhase
    data object Waiting : GatedPhase
    data class Unlocked(val markdown: String) : GatedPhase
    data class Failed(val message: String) : GatedPhase
}

/**
 * A Fanfares article: its teaser and a lock card with a pay button until the
 * key server says this reader has paid, then the decrypted article. A zap
 * made on the web or in another client opens it too ("Already paid?"), since
 * the key server only checks the zap receipt.
 */
@Composable
internal fun FanfaresGatedArticleBody(
    note: FeedNote,
    gated: GatedArticle,
    service: GatedArticleService,
    author: FeedProfile?,
    bodyStyle: TextStyle,
) {
    val colors = LocalNostrVaultColors.current
    val scope = rememberCoroutineScope()
    val reader = service.activeReader
    var phase by remember(note.id, reader) { mutableStateOf<GatedPhase>(GatedPhase.Checking) }
    // Shares of the price not yet paid. Fewer than all means money may have
    // moved already: the button then pays only what is left, or just
    // re-checks for the key, and never pays the same share twice.
    var unpaid by remember(note.id, reader) { mutableStateOf(service.unpaidShares(note, gated)) }
    var confirming by remember { mutableStateOf(false) }
    val paid = unpaid.size < gated.shares.size
    val dueSats = unpaid.sumOf { it.sats }
    val authorName = author?.bestName ?: "the author"
    val busy = phase == GatedPhase.Checking || phase == GatedPhase.Paying || phase == GatedPhase.Waiting

    // auto: the check that runs on open. It asks the signer only when that is
    // silent (a local key) or money has already moved; a remote signer would
    // otherwise prompt on every view. A stored key opens without asking.
    suspend fun checkAccess(auto: Boolean) {
        // A payment in flight owns the phase.
        if (phase == GatedPhase.Paying || phase == GatedPhase.Waiting) return
        unpaid = service.unpaidShares(note, gated)
        val moneyMoved = unpaid.size < gated.shares.size
        if (auto && !moneyMoved && !service.canCheckSilently) {
            phase = service.storedBody(note, gated)?.let { GatedPhase.Unlocked(it) } ?: GatedPhase.Locked
            return
        }
        phase = GatedPhase.Checking
        phase = try {
            GatedPhase.Unlocked(service.open(note, gated))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (phase != GatedPhase.Checking) return
            // Not paid yet is the normal case on open. On a check the reader
            // asked for, say why it didn't open; the way to pay stays open.
            if (auto || e !is GatedArticleService.UnlockError) GatedPhase.Locked else GatedPhase.Failed(e.message.orEmpty())
        }
    }

    suspend fun waitForKey() {
        phase = GatedPhase.Waiting
        phase = try {
            GatedPhase.Unlocked(service.waitForKey(note, gated))
        } catch (e: CancellationException) {
            throw e
        } catch (e: GatedArticleService.UnlockError.NotPaid) {
            GatedPhase.Failed(GatedLockCopy.RECEIPT_NOT_SEEN)
        } catch (e: Exception) {
            GatedPhase.Failed(e.message.orEmpty())
        }
    }

    suspend fun pay() {
        if (phase == GatedPhase.Checking || phase == GatedPhase.Paying || phase == GatedPhase.Waiting) return
        phase = GatedPhase.Paying
        try {
            service.pay(note, gated)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            unpaid = service.unpaidShares(note, gated)
            phase = GatedPhase.Failed(GatedLockCopy.payFailure(unpaid.size < gated.shares.size, e.message.orEmpty()))
            return
        }
        unpaid = service.unpaidShares(note, gated)
        waitForKey()
    }

    LaunchedEffect(note.id, reader) { checkAccess(auto = true) }

    val current = phase
    if (current is GatedPhase.Unlocked) {
        GatedUnlockedBody(current.markdown, bodyStyle)
        return
    }

    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text(GatedLockCopy.confirmTitle(gated.shares.size, dueSats, authorName)) },
            text = { Text("Your zap unlocks the full article.") },
            confirmButton = {
                TextButton(onClick = {
                    confirming = false
                    scope.launch { pay() }
                }) { Text("Zap $dueSats sats") }
            },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text("Cancel") } },
        )
    }

    GatedLockFrame(note, gated, bodyStyle) {
        Text(
            text = GatedLockCopy.status(
                author = authorName, priceSats = gated.priceSats, paid = paid,
                fullyPaid = paid && unpaid.isEmpty(), failure = (current as? GatedPhase.Failed)?.message,
                waiting = current == GatedPhase.Waiting,
            ),
            color = SecondaryText,
            fontSize = 14.sp,
        )
        Button(
            onClick = {
                if (paid && unpaid.isEmpty()) scope.launch { waitForKey() } else confirming = true
            },
            enabled = !busy,
            shape = RoundedCornerShape(10.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = colors.primary,
                contentColor = Color.White,
                disabledContainerColor = colors.primary.copy(alpha = 0.6f),
                disabledContentColor = Color.White,
            ),
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (busy) {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            } else {
                Icon(if (paid && unpaid.isEmpty()) Icons.Filled.Refresh else Icons.Filled.Bolt, contentDescription = null,
                    modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = when (current) {
                    GatedPhase.Paying -> "Zapping…"
                    GatedPhase.Waiting -> "Unlocking…"
                    GatedPhase.Checking -> "Checking…"
                    else -> GatedLockCopy.buttonLabel(gated.priceSats, paid, unpaid.isEmpty(), dueSats)
                },
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
        if ((current == GatedPhase.Locked || current is GatedPhase.Failed) && !paid) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { scope.launch { checkAccess(auto = false) } }) {
                    Icon(Icons.Outlined.CheckCircle, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Already paid?", fontSize = 13.sp)
                }
            }
        }
    }
}
