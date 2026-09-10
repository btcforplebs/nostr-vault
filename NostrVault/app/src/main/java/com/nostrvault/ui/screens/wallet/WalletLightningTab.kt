package com.nostrvault.ui.screens.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.components.DestructiveConfirmDialog
import com.nostrvault.ui.screens.WalletCaption
import com.nostrvault.ui.screens.WalletQr
import com.nostrvault.ui.screens.WalletSectionLabel
import com.nostrvault.ui.screens.WalletViewModel
import com.nostrvault.ui.screens.walletFieldColors
import com.nostrvault.ui.theme.*
import com.nostrvault.util.Bolt11
import com.nostrvault.util.Bolt11Amount

/**
 * Lightning (NWC) tab: balance, receive (create invoice + QR) and send (pay bolt11).
 * Port of iOS WalletLightningTab.
 */
@Composable
fun WalletLightningTab(viewModel: WalletViewModel) {
    val config by viewModel.config.collectAsState()
    val balance by viewModel.lightningBalance.collectAsState()
    val busy by viewModel.busy.collectAsState()
    val invoice by viewModel.generatedInvoice.collectAsState()
    val colors = LocalNostrVaultColors.current
    val clipboard = LocalClipboardManager.current

    if (config.nwcURI.isNullOrBlank()) {
        Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
            Text(
                "Connect a Lightning wallet in the Settings tab to send and receive.",
                color = SecondaryText, fontSize = 14.sp,
            )
        }
        return
    }

    var receiveAmount by remember { mutableStateOf("") }
    var receiveDesc by remember { mutableStateOf("") }
    var sendInvoice by remember { mutableStateOf("") }
    var showPayConfirm by remember { mutableStateOf(false) }

    // Decoded on every edit, so the amount is on screen before the button is,
    // not only inside the confirmation. A bolt11 string says nothing at a
    // glance.
    val pastedAmount = remember(sendInvoice) {
        Bolt11.amount(sendInvoice.trim())
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
    ) {
        // Balance
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text("Balance", color = SecondaryText, fontSize = 12.sp)
                Text(
                    text = balance?.let { "$it sats" } ?: "—",
                    color = PrimaryText, fontSize = 24.sp, fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                )
            }
            TextButton(onClick = viewModel::refreshBalance) { Text("Refresh", color = colors.primary) }
        }

        Spacer(Modifier.height(24.dp))

        // ── Receive ───────────────────────────────────────────────
        WalletSectionLabel("Receive")
        if (invoice == null) {
            OutlinedTextField(
                value = receiveAmount,
                onValueChange = { t -> receiveAmount = t.filter { it.isDigit() } },
                label = { Text("Amount (sats)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
                colors = walletFieldColors(colors.primary),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = receiveDesc,
                onValueChange = { receiveDesc = it },
                label = { Text("Description (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = walletFieldColors(colors.primary),
            )
            Spacer(Modifier.height(12.dp))
            Button(
                onClick = { viewModel.createInvoice(receiveAmount.toLongOrNull() ?: 0L, receiveDesc) },
                enabled = !busy && (receiveAmount.toLongOrNull() ?: 0L) > 0,
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                modifier = Modifier.fillMaxWidth(),
            ) { Text(if (busy) "Creating…" else "Create Invoice") }
        } else {
            WalletQr(invoice!!)
            Spacer(Modifier.height(8.dp))
            Text(
                text = invoice!!,
                color = SecondaryText, fontSize = 11.sp, fontFamily = FontFamily.Monospace,
                maxLines = 3,
            )
            Spacer(Modifier.height(8.dp))
            Row {
                OutlinedButton(onClick = { clipboard.setText(AnnotatedString(invoice!!)) }) {
                    Text("Copy Invoice")
                }
                Spacer(Modifier.width(8.dp))
                TextButton(onClick = { viewModel.clearInvoice(); receiveAmount = ""; receiveDesc = "" }) {
                    Text("Done", color = colors.primary)
                }
            }
        }

        Spacer(Modifier.height(28.dp))

        // ── Send ──────────────────────────────────────────────────
        WalletSectionLabel("Send")
        OutlinedTextField(
            value = sendInvoice,
            onValueChange = { sendInvoice = it },
            label = { Text("Paste a bolt11 invoice") },
            modifier = Modifier.fillMaxWidth(),
            minLines = 2,
            colors = walletFieldColors(colors.primary),
        )
        if (sendInvoice.isNotBlank()) {
            Spacer(Modifier.height(8.dp))
            when (pastedAmount) {
                is Bolt11Amount.Sats -> Text(
                    "Paying ${formatSats(pastedAmount.sats)} sats",
                    color = colors.primary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                )
                Bolt11Amount.Unspecified -> Text(
                    "This invoice names no amount — your wallet decides what to send, and may refuse it.",
                    color = SecondaryText, fontSize = 12.sp,
                )
                Bolt11Amount.Unreadable -> Text(
                    "Not an invoice this app can read. Check it before you pay.",
                    color = SecondaryText, fontSize = 12.sp,
                )
            }
        }
        Spacer(Modifier.height(12.dp))
        Button(
            onClick = { showPayConfirm = true },
            enabled = !busy && sendInvoice.isNotBlank(),
            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
            modifier = Modifier.fillMaxWidth(),
        ) { Text(if (busy) "Paying…" else "Pay Invoice") }

        WalletCaption("Payments use your connected NWC wallet.")
        Spacer(Modifier.height(32.dp))
    }

    if (showPayConfirm) {
        DestructiveConfirmDialog(
            title = "Pay Invoice",
            consequence = when (pastedAmount) {
                is Bolt11Amount.Sats ->
                    "This sends ${formatSats(pastedAmount.sats)} sats from your wallet. " +
                        "Lightning payments cannot be reversed."
                Bolt11Amount.Unspecified ->
                    "This invoice names no amount, so your wallet decides what to send — " +
                        "and it may refuse it outright. Lightning payments cannot be reversed."
                Bolt11Amount.Unreadable ->
                    "Nostr Vault cannot read this invoice, so it cannot tell you what it will " +
                        "cost. Your wallet will pay whatever it says. Lightning payments cannot " +
                        "be reversed."
            },
            confirmLabel = "Pay",
            onConfirm = { viewModel.payInvoice(sendInvoice); sendInvoice = "" },
            onDismiss = { showPayConfirm = false },
        )
    }
}

/** 21000 reads as 21,000 — the digit group is the point of showing it. */
private fun formatSats(sats: Long): String = "%,d".format(sats)
