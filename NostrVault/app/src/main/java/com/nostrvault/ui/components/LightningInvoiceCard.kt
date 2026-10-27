package com.nostrvault.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.NWCService
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface2
import com.nostrvault.ui.theme.ZapOrange
import com.nostrvault.util.Bolt11Amount
import com.nostrvault.util.NoteInvoices
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.NumberFormat

@EntryPoint
@InstallIn(SingletonComponent::class)
interface InvoiceCardEntryPoint {
    fun nwcService(): NWCService
    fun configStore(): ConfigStore
}

private sealed interface PayState {
    data object Idle : PayState
    data object Paying : PayState
    data object Paid : PayState
    data class Failed(val message: String) : PayState
}

/**
 * A Lightning invoice someone pasted into a note, drawn as something you can
 * read and pay: what it costs, what it is for, and whether it has lapsed.
 * Pays through the connected wallet (NWC), the same path as a zap.
 * Port of iOS LightningInvoiceCard (#1241).
 */
@Composable
fun LightningInvoiceCard(match: NoteInvoices.Match, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val services = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, InvoiceCardEntryPoint::class.java)
    }
    val config by services.configStore().config.collectAsState()
    val hasWallet = !config.nwcURI.isNullOrBlank()
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()

    var state by remember(match.invoice) { mutableStateOf<PayState>(PayState.Idle) }
    var confirming by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    // Re-read every 30 s so an invoice that lapses while on screen says so.
    var now by remember { mutableLongStateOf(System.currentTimeMillis() / 1000) }
    LaunchedEffect(match.invoice) {
        while (true) {
            delay(30_000)
            now = System.currentTimeMillis() / 1000
        }
    }
    LaunchedEffect(copied) {
        if (copied) { delay(1_500); copied = false }
    }

    val details = match.details
    val expired = details.isExpired(now)
    val failed = state is PayState.Failed
    val payEnabled = hasWallet && !expired && (state == PayState.Idle || failed)

    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        color = Surface2,
        border = BorderStroke(1.dp, ZapOrange.copy(alpha = if (expired) 0.12f else 0.35f)),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = NostrVaultIcons.Zap,
                    contentDescription = null,
                    tint = if (expired) SecondaryText else ZapOrange,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = amountText(details.amount),
                    color = if (expired) SecondaryText else PrimaryText,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                    textDecoration = if (expired) TextDecoration.LineThrough else null,
                )
                Spacer(Modifier.weight(1f).width(8.dp))
                Text(
                    text = statusText(state, expired, details.expiresAt - now),
                    color = if (expired) ErrorRed.copy(alpha = 0.85f) else SecondaryText,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                )
            }

            details.memo?.let { memo ->
                Text(
                    text = memo,
                    color = PrimaryText.copy(alpha = if (expired) 0.5f else 0.9f),
                    fontSize = 14.sp,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                val lit = payEnabled || state == PayState.Paid
                Row(
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = 36.dp)
                        .clip(CircleShape)
                        .background(if (lit) ZapOrange else Color.White.copy(alpha = 0.08f))
                        .clickable(enabled = payEnabled) { confirming = true }
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (state == PayState.Paying) {
                        CircularProgressIndicator(Modifier.size(14.dp), color = Color.Black, strokeWidth = 2.dp)
                    } else {
                        Icon(
                            imageVector = if (state == PayState.Paid) NostrVaultIcons.Check else NostrVaultIcons.Zap,
                            contentDescription = null,
                            tint = if (lit) Color.Black else SecondaryText,
                            modifier = Modifier.size(14.dp),
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = payLabel(state, expired),
                        color = if (lit) Color.Black else SecondaryText,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                Row(
                    modifier = Modifier
                        .heightIn(min = 36.dp)
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.08f))
                        .clickable {
                            clipboard.setText(AnnotatedString(match.invoice))
                            copied = true
                        }
                        .padding(horizontal = 12.dp, vertical = 8.dp)
                        .semantics { contentDescription = if (copied) "Invoice copied" else "Copy invoice" },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = if (copied) NostrVaultIcons.Check else NostrVaultIcons.Copy,
                        contentDescription = null,
                        tint = PrimaryText,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(if (copied) "Copied" else "Copy", color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                }
            }

            footnote(state, expired, hasWallet, details.amount)?.let { text ->
                Text(
                    text = text,
                    color = if (failed) ErrorRed.copy(alpha = 0.85f) else SecondaryText,
                    fontSize = 12.sp,
                )
            }
        }
    }

    if (confirming) {
        DestructiveConfirmDialog(
            title = "Pay this invoice?",
            consequence = confirmationMessage(details.amount, details.memo),
            confirmLabel = "Pay",
            onConfirm = {
                state = PayState.Paying
                scope.launch {
                    state = try {
                        services.nwcService().payInvoice(match.invoice)
                        PayState.Paid
                    } catch (e: Exception) {
                        PayState.Failed(e.message ?: "The payment failed.")
                    }
                }
            },
            onDismiss = { confirming = false },
        )
    }
}

// ── Words (the same as iOS) ────────────────────────────────────────

private fun sats(n: Long) = NumberFormat.getIntegerInstance().format(n)

private fun amountText(amount: Bolt11Amount) =
    if (amount is Bolt11Amount.Sats) "${sats(amount.sats)} sats" else "Any amount"

private fun statusText(state: PayState, expired: Boolean, leftSeconds: Long): String = when {
    state == PayState.Paid -> "Paid"
    expired -> "Expired"
    leftSeconds < 60 -> "Expires in under a minute"
    leftSeconds < 3600 -> "Expires in ${leftSeconds / 60} min"
    leftSeconds < 86_400 -> "Expires in ${leftSeconds / 3600} hr"
    else -> "Expires in ${leftSeconds / 86_400} ${if (leftSeconds / 86_400 == 1L) "day" else "days"}"
}

private fun payLabel(state: PayState, expired: Boolean) = when (state) {
    PayState.Paying -> "Paying…"
    PayState.Paid -> "Paid"
    is PayState.Failed -> "Try again"
    PayState.Idle -> if (expired) "Expired" else "Pay"
}

private fun footnote(state: PayState, expired: Boolean, hasWallet: Boolean, amount: Bolt11Amount): String? = when {
    state is PayState.Failed -> state.message
    state == PayState.Paid || expired -> null
    !hasWallet -> "Connect a wallet in the Wallet tab to pay invoices here."
    amount == Bolt11Amount.Unspecified -> "This invoice names no amount — your wallet decides, and may refuse it."
    else -> null
}

/** The last surface before the sats leave, so it repeats the number. */
private fun confirmationMessage(amount: Bolt11Amount, memo: String?): String {
    val forMemo = memo?.let { " for “$it”" } ?: ""
    return if (amount is Bolt11Amount.Sats) {
        "This sends ${sats(amount.sats)} sats$forMemo from your wallet. Lightning payments cannot be reversed."
    } else {
        "This invoice$forMemo names no amount, so your wallet decides what to send — and it may refuse it outright. Lightning payments cannot be reversed."
    }
}
