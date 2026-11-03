package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.screens.shareportal.forms.HighlightShareForm
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
                SharePortalSheetModel.Phase.Pick -> ActionList(model)
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
private fun ActionList(model: SharePortalSheetModel) {
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
            modifier = Modifier.fillMaxWidth().clickable { model.pick(action) },
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
