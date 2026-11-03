package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.PayShareTarget
import com.nostrvault.shareportal.ShareClassifier
import com.nostrvault.shareportal.ShareContactsSnapshot
import com.nostrvault.shareportal.ShareInput
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.screens.shareportal.forms.DMShareForm
import com.nostrvault.ui.screens.shareportal.forms.HighlightShareForm
import com.nostrvault.ui.screens.shareportal.forms.PayShareForm
import com.nostrvault.ui.theme.*

/**
 * The bottom sheet another app's share opens: the ranked actions that are
 * ready, then that action's small form, then "Queued". Twin: ShareCard.swift
 * with ShareActionList.swift.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SharePortalSheet(
    model: SharePortalSheetModel,
    onSend: (ShareIntent) -> Unit,
    onOpenNow: () -> Unit,
    onClose: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    ModalBottomSheet(onDismissRequest = onClose, containerColor = Surface1) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp).imePadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Nostr Vault", style = MaterialTheme.typography.titleMedium, color = colors.primary)
            when (val phase = model.phase) {
                SharePortalSheetModel.Phase.Loading -> CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally))
                SharePortalSheetModel.Phase.Pick -> ActionList(model) { action ->
                    // Only Highlight has a form here; the rest are finished on the app's review card.
                    if (action == ShareAction.HIGHLIGHT) model.pick(action)
                    else model.intent(action, emptyMap())?.let { model.sending(); onSend(it) }
                }
                is SharePortalSheetModel.Phase.Form -> when (phase.action) {
                    ShareAction.HIGHLIGHT -> HighlightShareForm(
                        url = model.read?.input?.let { it.url ?: com.nostrvault.shareportal.ShareClassifier.webUrl(it) },
                        initialPassage = model.read?.input?.let { it.selection ?: it.text }.orEmpty(),
                        accountLine = accountLine(model),
                        onBack = model::back,
                        onSend = { passage, comment ->
                            model.intent(ShareAction.HIGHLIGHT, mapOf("passage" to passage, "comment" to comment))?.let {
                                model.sending(); onSend(it)
                            }
                        },
                    )
                    ShareAction.PAY -> PayShareForm(
                        target = model.read?.input?.let { PayShareTarget.find(it.url, it.text, it.selection)?.token },
                        onBack = model::back,
                        onSend = { model.intent(ShareAction.PAY, emptyMap())?.let { model.sending(); onSend(it) } },
                    )
                    ShareAction.DM -> DMShareForm(
                        initialMessage = model.read?.input?.let { dmMessage(it) }.orEmpty(),
                        recent = recentContacts(model.account),
                        onBack = model::back,
                        onSend = { message, to ->
                            val form = buildMap { put("message", message); to?.let { put("to", it) } }
                            model.intent(ShareAction.DM, form)?.let { model.sending(); onSend(it) }
                        },
                    )
                    else -> Text("Not ready yet.", color = SecondaryText)
                }
                SharePortalSheetModel.Phase.Sending -> CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally))
                SharePortalSheetModel.Phase.Sent -> {
                    Text("Queued in Nostr Vault. Open the app to review and publish it.")
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(onClick = onOpenNow) { Text("Open now") }
                        TextButton(onClick = onClose) { Text("Done") }
                    }
                }
                SharePortalSheetModel.Phase.Failed -> {
                    Text("Couldn't queue this. Try sharing it again.", color = SecondaryText)
                    TextButton(onClick = onClose) { Text("Close") }
                }
            }
        }
    }
}

@Composable
private fun ActionList(model: SharePortalSheetModel, onPick: (ShareAction) -> Unit) {
    if (model.actions.isEmpty()) {
        Text("Nothing here Nostr Vault can use yet.", color = SecondaryText)
        return
    }
    model.read?.input?.let { input ->
        val what = input.title ?: input.url ?: input.selection ?: input.text
        what?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis, color = SecondaryText) }
    }
    model.actions.forEach { action ->
        Surface(
            color = Surface2,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().clickable { onPick(action) },
        ) {
            Text(label(action), Modifier.padding(16.dp))
        }
    }
}

private fun accountLine(model: SharePortalSheetModel): String? {
    val snapshot = model.accounts ?: return null
    if (snapshot.accounts.size < 2) return null
    val name = snapshot.accounts.firstOrNull { it.npub == model.account }?.name ?: return null
    return "As $name"
}

internal fun label(action: ShareAction): String = when (action) {
    ShareAction.HIGHLIGHT -> "Highlight"
    ShareAction.BOOKMARK -> "Save for later"
    ShareAction.PRIVATE_COPY -> "Keep a private copy"
    ShareAction.ARTICLE_CLIP -> "Clip to a draft"
    ShareAction.MEDIA_POST -> "Picture or video post"
    ShareAction.UPLOAD -> "Upload to my media servers"
    ShareAction.RECIPE -> "Save as a recipe"
    ShareAction.PROFILE -> "Open profile"
    ShareAction.PAY -> "Pay"
    ShareAction.DM -> "Send privately"
    ShareAction.STATUS -> "Set as now playing"
    ShareAction.CALENDAR -> "Add to calendar"
    ShareAction.LABEL -> "Flag this link"
}

/** Send privately starts from the shared title and link, else the shared text. Twin: DMShareForm.swift. */
private fun dmMessage(input: ShareInput): String {
    val url = ShareClassifier.webUrl(input)
    if (url != null) {
        val title = input.title?.trim().orEmpty()
        return if (title.isEmpty()) url else "$title\n$url"
    }
    return input.selection ?: input.text.orEmpty()
}

/** This account's recent private recipients, written by the app (lane D). */
@Composable
private fun recentContacts(account: String?): List<ShareContactsSnapshot.Contact> {
    val context = LocalContext.current
    return remember(account) {
        ShareContactsSnapshot.read(ShareContactsSnapshot.file(context))?.contacts(account).orEmpty()
    }
}
