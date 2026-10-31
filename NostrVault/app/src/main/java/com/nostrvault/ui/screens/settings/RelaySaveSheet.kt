package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.RelayDraft
import com.nostrvault.relay.RelayMatrix
import com.nostrvault.relay.RelayMatrix.Job
import com.nostrvault.ui.theme.*

internal fun Int.changesLabel(): String = "$this change${if (this == 1) "" else "s"}"

@Composable
internal fun RelaySaveBar(changes: Int, accent: Color, onSave: () -> Unit) {
    Column(Modifier.fillMaxWidth().background(Surface1).navigationBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp)) {
        Button(
            onClick = onSave,
            enabled = changes > 0,
            colors = ButtonDefaults.buttonColors(containerColor = accent),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (changes == 0) "No changes" else "Save (${changes.changesLabel()})", fontWeight = FontWeight.SemiBold)
        }
        Text("Only Save publishes. App defaults, Search and Import stay on this device.",
            color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
    }
}

/** What Save publishes and what stays here, list by list. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RelaySaveSheet(plan: RelayDraft.Plan, changes: Int, accent: Color, onSave: () -> Unit, onDismiss: () -> Unit) {
    val publishes = plan.relayListTags != null || plan.dmRelays != null
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Surface1,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Text("Save ${changes.changesLabel()}?", color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            ChangeGroup(
                "Relay list (kind 10002)", "Published. Other apps use it to find your posts and reach you.",
                plan.relayListChanges, accent,
                held = plan.relayListHeld,
            )
            ChangeGroup(
                "DM inbox (kind 10050)", "Published. People send your DMs here.",
                plan.dmChanges, accent,
                held = plan.dmListHeld,
                warning = "Empty: nobody will be able to send you DMs.".takeIf { plan.dmRelays?.isEmpty() == true },
            )
            ChangeGroup("On this device only", "App defaults, Search and Import. Never published.", plan.localChanges, accent)
            Text("Nothing else on your lists is touched.", color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 14.dp))
            Button(
                onClick = onSave,
                colors = ButtonDefaults.buttonColors(containerColor = accent),
                modifier = Modifier.fillMaxWidth().padding(top = 20.dp),
            ) { Text(if (publishes) "Save and publish" else "Save on this device", fontWeight = FontWeight.SemiBold) }
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text("Keep editing", color = accent) }
        }
    }
}

@Composable
private fun ChangeGroup(
    title: String,
    detail: String,
    changes: List<RelayDraft.Change>,
    accent: Color,
    held: Boolean = false,
    warning: String? = null,
) {
    Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 14.dp))
    Text(
        if (held) "Not published: your relays didn't send your current list, and publishing could replace one set in another app. Saved on this device."
        else detail,
        color = if (held) SlowAmber else SecondaryText, fontSize = 12.sp,
    )
    if (changes.isEmpty()) Text("Nothing changes", color = TertiaryText, fontSize = 14.sp, modifier = Modifier.padding(top = 4.dp))
    changes.forEach { change ->
        val label = RelayMatrix.label(change.url)
        fun names(jobs: Set<Job>) = Job.entries.filter { it in jobs }.joinToString(", ") { it.title }
        val (text, tint) = when {
            change.removed.isEmpty() -> "+  $label (${names(change.added)})" to accent
            change.added.isEmpty() -> "−  $label (${names(change.removed)})" to ErrorRed
            else -> "$label: + ${names(change.added)}, − ${names(change.removed)}" to PrimaryText
        }
        Text(text, color = tint, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 4.dp))
    }
    if (warning != null) Text(warning, color = ErrorRed, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))
}

/** Lists the last Save kept on this device because the newest copy couldn't be read at Save. */
@Composable
internal fun RelayNotPublishedBanner(notPublished: List<String>) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text("!", color = SlowAmber, fontWeight = FontWeight.Bold, fontSize = 18.sp, modifier = Modifier.width(20.dp))
        Text(
            "${notPublished.joinToString(" and ")} not published: your relays didn't answer, so the newest copy " +
                "couldn't be read. Saved on this device only.",
            color = SecondaryText, fontSize = 12.sp,
        )
    }
}
