package com.nostrvault.ui.screens.wallet

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.LNURLPayResponse
import com.nostrvault.service.LNURLResolved
import com.nostrvault.service.LNURLService
import com.nostrvault.service.LNURLWithdrawResponse
import com.nostrvault.ui.components.DestructiveConfirmDialog
import com.nostrvault.ui.screens.WalletCaption
import com.nostrvault.ui.screens.WalletQr
import com.nostrvault.ui.screens.WalletSectionLabel
import com.nostrvault.ui.screens.WalletViewModel
import com.nostrvault.ui.screens.walletFieldColors
import com.nostrvault.ui.theme.*
import com.nostrvault.util.Bolt11
import com.nostrvault.util.Bolt11Amount
import com.nostrvault.util.LNURLAmountRange
import com.nostrvault.util.LightningPayTarget
import com.nostrvault.util.WalletTransaction
import com.nostrvault.util.ZapDetail
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.util.lnurlPlainTextMetadata
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/**
 * Lightning (NWC) tab: balance, receive (create invoice + QR), send (bolt11,
 * lightning address, LNURL pay/withdraw) and payment history.
 * Port of iOS WalletLightningTab.
 */
@Composable
fun WalletLightningTab(viewModel: WalletViewModel, onNoteClick: (String) -> Unit = {}) {
    val config by viewModel.config.collectAsState()
    val balance by viewModel.lightningBalance.collectAsState()
    val busy by viewModel.busy.collectAsState()
    val invoice by viewModel.generatedInvoice.collectAsState()
    val colors = LocalNostrVaultColors.current
    val clipboard = LocalClipboardManager.current

    LaunchedEffect(config.nwcURI) {
        if (!config.nwcURI.isNullOrBlank()) viewModel.loadHistory(reset = true)
    }

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
    var sendText by remember { mutableStateOf("") }
    var showPayConfirm by remember { mutableStateOf(false) }

    // Whatever was pasted: invoice, lightning address, LNURL, LUD-17 link,
    // with or without a `lightning:` / BIP21 wrapper.
    val payTarget = remember(sendText) { LightningPayTarget.parse(sendText) }

    // Decoded on every edit, so the amount is on screen before the button is,
    // not only inside the confirmation. A bolt11 string says nothing at a
    // glance.
    val pastedAmount = remember(payTarget) {
        Bolt11.amount((payTarget as? LightningPayTarget.Invoice)?.bolt11 ?: "")
    }

    // Lightning address / LNURL, looked up once the user stops typing.
    var resolved by remember { mutableStateOf<LNURLResolved?>(null) }
    var isResolving by remember { mutableStateOf(false) }
    var resolveError by remember { mutableStateOf<String?>(null) }
    var lnurlAmount by remember { mutableStateOf("") }
    var lnurlComment by remember { mutableStateOf("") }
    var showLnurlPayConfirm by remember { mutableStateOf(false) }

    /** Who the money goes to (or comes from), in the words the user typed. */
    val counterparty = (payTarget as? LightningPayTarget.Address)?.address
        ?: resolved?.host
        ?: "this service"

    LaunchedEffect(payTarget) {
        resolved = null
        resolveError = null
        lnurlComment = ""
        showLnurlPayConfirm = false
        val target = payTarget
        if (target == null || target is LightningPayTarget.Invoice) {
            isResolving = false
            return@LaunchedEffect
        }
        isResolving = true
        delay(400)
        try {
            val r = LNURLService.resolve(target)
            resolved = r
            lnurlAmount = when (r) {
                is LNURLResolved.Pay -> {
                    val range = LNURLAmountRange(r.pay.minSendable, r.pay.maxSendable)
                    if (range.isFixed) range.minSats.toString() else ""
                }
                // A voucher is usually meant to be taken whole.
                is LNURLResolved.Withdraw ->
                    LNURLAmountRange(r.withdraw.minWithdrawable, r.withdraw.maxWithdrawable).maxSats.toString()
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            resolveError = if (target is LightningPayTarget.Address) {
                "Couldn't find the lightning address ${target.address}. Check the spelling. (${e.message})"
            } else {
                "Couldn't open this LNURL: ${e.message}"
            }
        }
        isResolving = false
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
            value = sendText,
            onValueChange = { sendText = it },
            label = { Text("Invoice, lightning address or LNURL") },
            modifier = Modifier.fillMaxWidth(),
            minLines = 2,
            maxLines = 4,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                keyboardType = KeyboardType.Ascii,
            ),
            colors = walletFieldColors(colors.primary),
        )
        when (val target = payTarget) {
            null -> if (sendText.isNotBlank()) {
                WalletCaption(
                    "Not something this wallet can pay. Paste a lightning invoice, a lightning " +
                        "address (name@domain.com) or an LNURL."
                )
            }
            is LightningPayTarget.Invoice -> {
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
                Spacer(Modifier.height(12.dp))
                Button(
                    onClick = { showPayConfirm = true },
                    enabled = !busy,
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(if (busy) "Paying…" else "Pay Invoice") }
            }
            is LightningPayTarget.Address,
            is LightningPayTarget.Lnurl,
            is LightningPayTarget.LnurlUrl -> {
                Spacer(Modifier.height(8.dp))
                when {
                    isResolving -> Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = SecondaryText)
                        Spacer(Modifier.width(8.dp))
                        Text("Looking it up…", color = SecondaryText, fontSize = 12.sp)
                    }
                    resolveError != null -> Text(resolveError!!, color = ErrorRed, fontSize = 12.sp)
                    else -> when (val r = resolved) {
                        is LNURLResolved.Pay -> LnurlPayPanel(
                            pay = r.pay,
                            counterparty = counterparty,
                            amount = lnurlAmount,
                            onAmountChange = { lnurlAmount = it },
                            comment = lnurlComment,
                            onCommentChange = { lnurlComment = it },
                            busy = busy,
                            onSend = { showLnurlPayConfirm = true },
                        )
                        is LNURLResolved.Withdraw -> LnurlWithdrawPanel(
                            withdraw = r.withdraw,
                            counterparty = counterparty,
                            amount = lnurlAmount,
                            onAmountChange = { lnurlAmount = it },
                            busy = busy,
                            onReceive = { msat ->
                                viewModel.withdrawLnurl(r.withdraw, msat, counterparty) { sendText = "" }
                            },
                        )
                        null -> {}
                    }
                }
            }
        }

        WalletCaption("Payments use your connected NWC wallet.")

        Spacer(Modifier.height(28.dp))

        // ── History ───────────────────────────────────────────────
        WalletHistory(viewModel, onNoteClick)
        Spacer(Modifier.height(32.dp))
    }

    if (showPayConfirm) {
        val bolt11 = (payTarget as? LightningPayTarget.Invoice)?.bolt11
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
            onConfirm = { if (bolt11 != null) { viewModel.payInvoice(bolt11); sendText = "" } },
            onDismiss = { showPayConfirm = false },
        )
    }

    if (showLnurlPayConfirm) {
        val pay = (resolved as? LNURLResolved.Pay)?.pay
        val range = pay?.let { LNURLAmountRange(it.minSendable, it.maxSendable) }
        val check = range?.check(lnurlAmount.toLongOrNull())
        if (pay != null && check is LNURLAmountRange.Check.Ok) {
            val name = counterparty
            DestructiveConfirmDialog(
                title = "Send Payment",
                consequence = "This sends ${formatSats(check.msat / 1000)} sats from your wallet to " +
                    "$name. Lightning payments cannot be reversed.",
                confirmLabel = "Send",
                onConfirm = {
                    viewModel.payLnurl(pay, check.msat, name, lnurlComment) { sendText = "" }
                },
                onDismiss = { showLnurlPayConfirm = false },
            )
        }
    }
}

// ── Lightning address / LNURL panels ──────────────────────────────

@Composable
private fun LnurlPayPanel(
    pay: LNURLPayResponse,
    counterparty: String,
    amount: String,
    onAmountChange: (String) -> Unit,
    comment: String,
    onCommentChange: (String) -> Unit,
    busy: Boolean,
    onSend: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val range = LNURLAmountRange(pay.minSendable, pay.maxSendable)
    val note = remember(pay.metadata) { lnurlPlainTextMetadata(pay.metadata) }
    val commentLimit = pay.commentAllowed ?: 0
    val check = range.check(amount.toLongOrNull())

    Column {
        Text("To $counterparty", color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        if (note != null) {
            Text(note, color = SecondaryText, fontSize = 12.sp, maxLines = 3)
        }
        Spacer(Modifier.height(10.dp))
        LnurlAmountInput(range, check, amount, onAmountChange, fixedColor = colors.primary)
        if (commentLimit > 0) {
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = comment,
                onValueChange = { onCommentChange(it.take(commentLimit)) },
                label = { Text("Comment (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = walletFieldColors(colors.primary),
            )
        }
        Spacer(Modifier.height(12.dp))
        Button(
            onClick = onSend,
            enabled = !busy && check is LNURLAmountRange.Check.Ok,
            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                when {
                    busy -> "Sending…"
                    check is LNURLAmountRange.Check.Ok -> "Send ${formatSats(check.msat / 1000)} sats"
                    else -> "Send"
                }
            )
        }
    }
}

@Composable
private fun LnurlWithdrawPanel(
    withdraw: LNURLWithdrawResponse,
    counterparty: String,
    amount: String,
    onAmountChange: (String) -> Unit,
    busy: Boolean,
    onReceive: (msat: Long) -> Unit,
) {
    val range = LNURLAmountRange(withdraw.minWithdrawable, withdraw.maxWithdrawable)
    val check = range.check(amount.toLongOrNull())

    Column {
        Text("Receive from $counterparty", color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        withdraw.defaultDescription?.takeIf { it.isNotEmpty() }?.let {
            Text(it, color = SecondaryText, fontSize = 12.sp, maxLines = 3)
        }
        Spacer(Modifier.height(10.dp))
        LnurlAmountInput(range, check, amount, onAmountChange, fixedColor = SuccessGreen)
        Spacer(Modifier.height(12.dp))
        Button(
            onClick = { (check as? LNURLAmountRange.Check.Ok)?.let { onReceive(it.msat) } },
            enabled = !busy && check is LNURLAmountRange.Check.Ok,
            colors = ButtonDefaults.buttonColors(containerColor = SuccessGreen),
            modifier = Modifier.fillMaxWidth(),
        ) { Text(if (busy) "Receiving…" else "Receive") }
    }
}

/** A fixed amount is stated, not asked for; a range gets a field and a caption. */
@Composable
private fun LnurlAmountInput(
    range: LNURLAmountRange,
    check: LNURLAmountRange.Check,
    amount: String,
    onAmountChange: (String) -> Unit,
    fixedColor: Color,
) {
    val colors = LocalNostrVaultColors.current
    if (range.isFixed) {
        Text(
            "Amount: ${formatSats(range.minSats)} sats",
            color = fixedColor, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
        )
        return
    }
    OutlinedTextField(
        value = amount,
        onValueChange = { t -> onAmountChange(t.filter { it.isDigit() }) },
        label = { Text("Amount (sats)") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = Modifier.fillMaxWidth(),
        colors = walletFieldColors(colors.primary),
    )
    val outOfRange = check is LNURLAmountRange.Check.TooSmall || check is LNURLAmountRange.Check.TooLarge
    Text(
        text = when (check) {
            is LNURLAmountRange.Check.TooSmall ->
                "The smallest amount it accepts is ${formatSats(check.minSats)} sats."
            is LNURLAmountRange.Check.TooLarge ->
                "The largest amount it accepts is ${formatSats(check.maxSats)} sats."
            else -> "Between ${formatSats(range.minSats)} and ${formatSats(range.maxSats)} sats."
        },
        color = if (outOfRange) ErrorRed else SecondaryText,
        fontSize = 12.sp,
        modifier = Modifier.padding(top = 6.dp),
    )
}

// ── History ───────────────────────────────────────────────────────

@Composable
private fun WalletHistory(viewModel: WalletViewModel, onNoteClick: (String) -> Unit) {
    val transactions by viewModel.transactions.collectAsState()
    val zapDetails by viewModel.zapDetails.collectAsState()
    val zapPosts by viewModel.zapPosts.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val me = viewModel.myPubkey
    val loading by viewModel.historyLoading.collectAsState()
    val error by viewModel.historyError.collectAsState()
    val unsupported by viewModel.historyUnsupported.collectAsState()
    val canLoadMore by viewModel.canLoadMoreHistory.collectAsState()

    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) { WalletSectionLabel("History") }
        if (loading) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = SecondaryText)
        } else if (!unsupported) {
            IconButton(onClick = { viewModel.loadHistory(reset = true) }, modifier = Modifier.size(32.dp)) {
                Icon(
                    NostrVaultIcons.Refresh, contentDescription = "Refresh history",
                    tint = SecondaryText, modifier = Modifier.size(18.dp),
                )
            }
        }
    }

    when {
        unsupported -> WalletCaption(
            "Your wallet doesn't share its payment history with apps. If it supports it, " +
                "reconnect the wallet with \"transaction history\" (list transactions) allowed."
        )
        error != null && transactions.isEmpty() -> Text(error!!, color = ErrorRed, fontSize = 12.sp)
        transactions.isEmpty() && !loading -> WalletCaption("No payments yet.")
        else -> {
            val now = System.currentTimeMillis()
            transactions.forEachIndexed { index, tx ->
                val zap = zapDetails[tx.id]
                val person = zap?.counterparty(me, tx.direction)
                TransactionRow(
                    tx, now,
                    zap = zap,
                    person = person,
                    profile = person?.let { profiles[it] },
                    post = zap?.postId?.let { zapPosts[it] },
                    onNoteClick = onNoteClick,
                )
                if (index != transactions.lastIndex) {
                    HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
                }
            }
            if (canLoadMore) {
                Spacer(Modifier.height(8.dp))
                OutlinedButton(
                    onClick = { viewModel.loadHistory(reset = false) },
                    enabled = !loading,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Show more") }
            }
        }
    }
}

/**
 * One history row. A zap shows who it came from (or went to) and what it was
 * on, and opens the zapped post on tap; anything else is just a row.
 */
@Composable
private fun TransactionRow(
    tx: WalletTransaction,
    nowMillis: Long,
    zap: ZapDetail?,
    person: String?,
    profile: FeedProfile?,
    post: FeedNote?,
    onNoteClick: (String) -> Unit,
) {
    val incoming = tx.direction == WalletTransaction.Direction.INCOMING
    val tint = if (zap != null || !incoming) ZapOrange else SuccessGreen
    val dead = tx.state == WalletTransaction.State.FAILED || tx.state == WalletTransaction.State.EXPIRED
    // The note-detail screen fetches a post it does not have, so a known id
    // is enough to open it.
    val postId = zap?.postId
    val context = zapContextLine(zap, post, incoming)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (postId != null) Modifier.clickable { onNoteClick(postId) } else Modifier)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (person != null) {
            Box(Modifier.size(28.dp)) {
                AvatarImage(
                    url = profile?.pictureURL, pubkey = person, size = 28.dp,
                    displayName = profile?.bestName,
                )
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .offset(x = 3.dp, y = 3.dp)
                        .size(13.dp)
                        .clip(CircleShape)
                        .background(ZapOrange),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(NostrVaultIcons.Zap, contentDescription = "Zap", tint = Color.White, modifier = Modifier.size(9.dp))
                }
            }
        } else {
            Box(
                modifier = Modifier.size(28.dp).clip(CircleShape).background(tint.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    when {
                        zap != null -> NostrVaultIcons.Zap
                        incoming -> NostrVaultIcons.Incoming
                        else -> NostrVaultIcons.Outgoing
                    },
                    contentDescription = when {
                        zap != null -> "Zap"
                        incoming -> "Received"
                        else -> "Sent"
                    },
                    tint = tint, modifier = Modifier.size(16.dp),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                transactionTitle(tx, zap, person, profile),
                color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            if (context != null) {
                Text(
                    context,
                    color = SecondaryText, fontSize = 12.sp,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                transactionSubtitle(tx, nowMillis),
                color = if (dead) ErrorRed else SecondaryText, fontSize = 12.sp,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(
            "${if (incoming) "+" else "−"}${formatSats(tx.amountSats)}",
            color = when {
                tx.state != WalletTransaction.State.SETTLED -> SecondaryText
                incoming -> SuccessGreen
                else -> PrimaryText
            },
            fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
            textDecoration = if (dead) TextDecoration.LineThrough else null,
        )
    }
}

private fun transactionTitle(
    tx: WalletTransaction,
    zap: ZapDetail?,
    person: String?,
    profile: FeedProfile?,
): String {
    val incoming = tx.direction == WalletTransaction.Direction.INCOMING
    if (zap == null) return tx.description ?: if (incoming) "Received" else "Sent"
    if (incoming && zap.isAnonymous) return "Anonymous zap"
    if (person == null) return if (incoming) "Zap received" else "Zap sent"
    val name = profile?.bestName ?: ("npub…" + person.takeLast(6))
    return if (incoming) "Zap from $name" else "Zap to $name"
}

/** What the zap was for: the sender's comment, else the start of the post. */
private fun zapContextLine(zap: ZapDetail?, post: FeedNote?, incoming: Boolean): String? {
    if (zap == null) return null
    zap.comment?.let { return "\u201C$it\u201D" }
    if (post != null) {
        val text = post.content.replace("\n", " ").trim()
        return if (text.isEmpty()) "on a post" else "on: $text"
    }
    return when {
        zap.postId != null -> "on a post"
        incoming -> "on your profile"
        else -> "on their profile"
    }
}

private fun transactionSubtitle(tx: WalletTransaction, nowMillis: Long): String {
    val parts = mutableListOf(
        DateUtils.getRelativeTimeSpanString(tx.createdAt * 1000, nowMillis, DateUtils.MINUTE_IN_MILLIS).toString()
    )
    when (tx.state) {
        WalletTransaction.State.PENDING -> parts += "pending"
        WalletTransaction.State.FAILED -> parts += "failed"
        WalletTransaction.State.EXPIRED -> parts += "expired"
        WalletTransaction.State.SETTLED -> {}
    }
    if (tx.direction == WalletTransaction.Direction.OUTGOING && tx.feeSats > 0) {
        parts += "fee ${formatSats(tx.feeSats)}"
    }
    return parts.joinToString(" · ")
}

/** 21000 reads as 21,000 — the digit group is the point of showing it. */
private fun formatSats(sats: Long): String = "%,d".format(sats)
