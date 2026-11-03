package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.service.shareportal.handlers.PayShareHandler
import com.nostrvault.shareportal.PayShareTarget
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.components.DestructiveConfirmDialog
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.util.Bolt11Amount
import com.nostrvault.util.Bolt11Details
import com.nostrvault.util.LNURLAmountRange
import kotlinx.coroutines.delay

/**
 * Review card for a shared invoice, lightning address or LNURL. The amount
 * is on the card and in the confirm; nothing leaves the wallet before that
 * confirm. Twin: PayReviewView.swift.
 */
@Composable
internal fun PayReviewContent(
    intent: ShareIntent,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onDismiss: () -> Unit,
    viewModel: PayReviewViewModel = hiltViewModel(key = "share-pay-${intent.id}"),
) {
    val target = remember(intent.id) { PayShareHandler.target(intent) }
    val busy by viewModel.busy.collectAsState()
    val error by viewModel.error.collectAsState()
    val done by viewModel.done.collectAsState()
    val lnurl by viewModel.lnurl.collectAsState()
    val tick by viewModel.attemptTick.collectAsState()
    val attempt = remember(intent.id, tick) { viewModel.attempt(intent) }
    var amountText by remember(intent.id) { mutableStateOf("") }
    var comment by remember(intent.id) { mutableStateOf("") }
    var asZap by remember(intent.id) { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis() / 1000) }
    LaunchedEffect(intent.id) {
        target?.let(viewModel::resolve)
        while (true) { delay(30_000); now = System.currentTimeMillis() / 1000 }
    }

    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Pay or zap", style = MaterialTheme.typography.titleMedium)
        if (target == null) {
            Text("There's nothing here Nostr Vault can pay.", color = SecondaryText)
            TextButton(onClick = onDismiss) { Text("Dismiss") }
            return@Column
        }

        val invoice = target.takeIf { it.kind == PayShareTarget.Kind.INVOICE }?.let { Bolt11Details.read(it.token) }
        val ready = (lnurl as? PayReviewViewModel.Lnurl.Ready)
        val range = ready?.let { LNURLAmountRange(it.pay.minSendable, it.pay.maxSendable) }
        val check = range?.check(amountText.toLongOrNull())
        val zapOffered = ready != null && viewModel.zapOffered(target, ready.pay)

        when {
            target.kind == PayShareTarget.Kind.INVOICE && invoice == null ->
                Text("This invoice can't be read, so it can't be paid here.", color = SecondaryText)
            invoice != null -> {
                Text(satsText(invoice.amount), fontSize = 24.sp, fontWeight = FontWeight.Bold)
                invoice.memo?.let { Text(it, maxLines = 3, overflow = TextOverflow.Ellipsis) }
                Text(
                    if (invoice.isExpired(now)) "Expired" else "Expires in ${minutesLeft(invoice.expiresAt - now)}",
                    color = if (invoice.isExpired(now)) ErrorRed else SecondaryText,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            else -> {
                Text("To ${if (target.kind == PayShareTarget.Kind.ADDRESS) target.token else ready?.host ?: "LNURL"}",
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
                when (val l = lnurl) {
                    PayReviewViewModel.Lnurl.Resolving, PayReviewViewModel.Lnurl.Idle -> CircularProgressIndicator()
                    is PayReviewViewModel.Lnurl.Failed -> Text(l.message, color = ErrorRed)
                    is PayReviewViewModel.Lnurl.Ready -> {
                        LaunchedEffect(l) { if (range!!.isFixed && amountText.isEmpty()) amountText = range.minSats.toString() }
                        OutlinedTextField(
                            value = amountText,
                            onValueChange = { v -> amountText = v.filter(Char::isDigit).take(12) },
                            label = { Text("Amount in sats") },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text(
                            if (range!!.isFixed) "This service takes exactly ${"%,d".format(range.minSats)} sats."
                            else "${"%,d".format(range.minSats)}–${"%,d".format(range.maxSats)} sats.",
                            color = SecondaryText, style = MaterialTheme.typography.bodySmall,
                        )
                        if ((l.pay.commentAllowed ?: 0) > 0 || zapOffered) {
                            OutlinedTextField(value = comment, onValueChange = { comment = it.take(280) },
                                label = { Text("Note (optional)") }, maxLines = 3, modifier = Modifier.fillMaxWidth())
                        }
                        if (zapOffered) {
                            Row {
                                Text("Send as a public zap to ${viewModel.recipientName(viewModel.recipientHex(target)!!)}",
                                    Modifier.weight(1f))
                                Switch(checked = asZap, onCheckedChange = { asZap = it })
                            }
                        }
                    }
                }
            }
        }

        if (!viewModel.hasWallet) Text("Connect a wallet on the Wallet screen first.", color = SecondaryText)
        val wanted = intent.account
        if (wanted != null && needsSwitch) {
            Text("This was shared for another of your accounts. Its wallet pays.", color = SecondaryText)
            OutlinedButton(onClick = { onSwitchAccount(wanted) }) { Text("Switch to that account") }
        }
        error?.let { Text(it, color = ErrorRed) }

        val lnurlBlocked = target.kind != PayShareTarget.Kind.INVOICE && attempt != null
        if (lnurlBlocked && done == null) Text(PayReviewViewModel.ALREADY_TRIED, color = SecondaryText)
        if (done != null) {
            Text(done!!)
            Button(onClick = onDismiss) { Text("Done") }
            return@Column
        }
        val canPay = viewModel.hasWallet && !busy && !needsSwitch && when (target.kind) {
            PayShareTarget.Kind.INVOICE -> invoice != null && invoice.amount is Bolt11Amount.Sats &&
                !invoice.isExpired(now) && attempt != PayShareAttempts.State.PAID
            else -> !lnurlBlocked && check is LNURLAmountRange.Check.Ok
        }
        val title = when {
            invoice != null -> "Pay ${satsText(invoice.amount)}"
            check is LNURLAmountRange.Check.Ok -> (if (asZap) "Zap " else "Pay ") + "${"%,d".format(check.msat / 1000)} sats"
            else -> "Pay"
        }
        Text("Lightning payments can't be reversed.", color = SecondaryText, style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { confirming = true }, enabled = canPay) { Text(if (busy) "Paying…" else title) }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }

        if (confirming) {
            val consequence = if (invoice != null) {
                "This sends ${satsText(invoice.amount)}${invoice.memo?.let { " for “$it”" }.orEmpty()} from your wallet. " +
                    "Lightning payments can't be reversed."
            } else {
                val sats = (check as? LNURLAmountRange.Check.Ok)?.msat?.div(1000) ?: 0
                val to = if (target.kind == PayShareTarget.Kind.ADDRESS) target.token else ready?.host.orEmpty()
                "This sends ${"%,d".format(sats)} sats to $to${if (asZap) " as a public zap" else ""}. " +
                    "Lightning payments can't be reversed."
            }
            DestructiveConfirmDialog(
                title = "Send this payment?",
                consequence = consequence,
                confirmLabel = "Pay",
                onConfirm = {
                    if (invoice != null) viewModel.payInvoice(intent, target.token)
                    else if (ready != null && check is LNURLAmountRange.Check.Ok) {
                        viewModel.payLnurl(intent, target, ready.pay, ready.host, check.msat, comment, asZap)
                    }
                },
                onDismiss = { confirming = false },
            )
        }
    }
}

private fun satsText(amount: Bolt11Amount): String =
    if (amount is Bolt11Amount.Sats) "${"%,d".format(amount.sats)} sats" else "No amount"

private fun minutesLeft(seconds: Long): String = when {
    seconds < 60 -> "under a minute"
    seconds < 3600 -> "${seconds / 60} min"
    seconds < 86_400 -> "${seconds / 3600} h"
    else -> "${seconds / 86_400} days"
}
