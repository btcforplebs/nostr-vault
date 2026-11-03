package com.nostrvault.ui.screens.settings.listbackup

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.ListBackupService
import com.nostrvault.service.ListHistory
import com.nostrvault.service.ListMergeSave
import com.nostrvault.service.ListShrinkRule
import com.nostrvault.service.ListVersionMerge
import com.nostrvault.service.ListVersionSave
import com.nostrvault.ui.components.rememberCanSign
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.launch

/**
 * Merge versions of one list: every version, one summary line each with a
 * tick, and one "Merge + save" that merges the ticked ones with the list now
 * and saves after one confirm (Logen 2026-11-02: small, no long checklist).
 * Per-entry ticks only behind Review ([ListMergeReview]). Only the list now
 * is decrypted on open; an older version when it is ticked; newer locked ones
 * on the Merge tap. Nothing merges or saves by itself. Web twin:
 * web-vault/src/screens/RecoverListPage.jsx (ListVersions).
 */
@Composable
internal fun ListMergeScreen(key: ListHistory.Key, viewModel: ListBackupViewModel, onBack: () -> Unit) {
    val name = ListVersionMerge.mergeKind(key.kind)?.name ?: ListShrinkRule.name(key.kind)
    val canSign = rememberCanSign()
    val scope = rememberCoroutineScope()
    var load by remember { mutableIntStateOf(0) }
    var start by remember { mutableStateOf<ListBackupService.MergeStart?>(null) }
    var picked by remember { mutableStateOf(emptySet<String>()) }
    var rows by remember { mutableStateOf<List<ListVersionMerge.Row>?>(null) }
    var review by remember { mutableStateOf(false) }
    var opening by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf("") }

    LaunchedEffect(load) {
        start = null
        start = viewModel.mergeStart(key)
        picked = emptySet()
        rows = null
        review = false
    }

    val loaded = start
    val current = loaded?.current
    val save: suspend () -> String? = save@{
        val merged = rows ?: return@save null
        val authors = loaded?.versions.orEmpty().filter { it.v.id in picked || it.v.id == current?.v?.id }.map { it.v.pubkey }.toSet()
        when (val out = viewModel.saveMerge(key, current, authors, merged)) {
            is ListVersionSave.Outcome.Saved -> {
                val total = ListVersionMerge.mergeSummary(key.kind, merged).total
                msg = "Saved: your ${name.lowercase()} now has ${entryCount(total)}. The list you had stays in your vault's history."
                load++
                null
            }
            is ListVersionSave.Outcome.Refused -> if (out.changed) { msg = out.message; load++; null } else out.message
        }
    }
    val confirm: @Composable () -> Unit = {
        rows?.let { merged ->
            ListMergeConfirm(
                kind = key.kind, name = name, rows = merged, review = review,
                nip44Note = ListMergeSave.needsNip44Note(key.kind, current?.v?.content, merged),
                onReview = { review = true }, onCancel = { rows = null; review = false }, onSave = save,
            )
        }
    }
    val merged = rows
    if (merged != null && review) {
        BackHandler { review = false }
        ListMergeReview(kind = key.kind, name = name, rows = merged, profiles = viewModel.profiles, fetch = viewModel::fetchProfiles, onRows = { rows = it }, onBack = { review = false }, confirm = confirm)
        return
    }

    ListBackupScaffold(title = "Merge $name", onBack = onBack) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 16.dp,
                start = 16.dp,
                end = 16.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            if (loaded == null) {
                item {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text("Checking your newest ${name.lowercase()}…", color = SecondaryText)
                    }
                }
                return@LazyColumn
            }
            val others = loaded.versions.filter { it.v.id != current?.v?.id }
            val chosen = others.filter { it.v.id in picked }
            item {
                ListRow(onClick = null) {
                    val now = if (current != null) {
                        "Your ${name.lowercase()} now: ${entryCount(current.entries.size)}, from ${ListBackupFormat.date(current.v.createdAt)}."
                    } else if (loaded.checked) "No current ${name.lowercase()} list of yours was found." else loaded.why
                    Text(now, color = SecondaryText, fontSize = 13.sp)
                    if (current != null && current.reason.isNotEmpty()) {
                        Text("Its private part can't be opened (${current.reason}), so it can't be merged.", color = Color(0xFFFF9500), fontSize = 13.sp)
                    }
                    if (msg.isNotEmpty()) Text(msg, color = PrimaryText, fontSize = 13.sp)
                }
            }
            if (others.isEmpty()) {
                item { Text("No older version of this list is kept yet. Your vault keeps one each time the list changes.", color = SecondaryText, fontSize = 13.sp) }
            }
            itemsIndexed(others, key = { _, v -> v.v.id }) { _, v ->
                val j = loaded.versions.indexOfFirst { it.v.id == v.v.id }
                VersionRow(kind = key.kind, v = v, wipe = ListVersionMerge.wasWipe(loaded.versions, j), current = current, picked = v.v.id in picked) {
                    rows = null
                    scope.launch {
                        val id = v.v.id
                        if (v.locked && id !in picked) {
                            val opened = ListVersionMerge.openVersion(v.v, viewModel.opener(v.v.pubkey))
                            start = start?.let { s -> s.copy(versions = s.versions.map { x -> if (x.v.id == id) opened else x }) }
                            if (opened.reason.isNotEmpty()) return@launch
                        }
                        picked = if (id in picked) picked - id else picked + id
                    }
                }
            }
            item {
                when {
                    !canSign -> Text("This account is read-only here, so nothing can be saved.", color = SecondaryText, fontSize = 13.sp)
                    others.isEmpty() -> {}
                    merged != null -> confirm()
                    else -> Column {
                        val enough = chosen.size >= (if (current != null) 1 else 2)
                        val ready = enough && loaded.checked && (current == null || current.reason.isEmpty()) && !opening
                        Button(enabled = ready, onClick = {
                            opening = true
                            scope.launch {
                                try {
                                    val opener = viewModel.opener(chosen.first().v.pubkey)
                                    val opened = ListVersionMerge.openForMerge(loaded.versions, chosen, opener)
                                    start = loaded.copy(versions = opened)
                                    val ids = chosen.map { it.v.id }.toSet()
                                    rows = ListVersionMerge.buildMerge(current, opened.filter { it.v.id in ids }, opened, loaded.vault)
                                } finally {
                                    opening = false
                                }
                            }
                        }) { Text(if (opening) "Opening versions…" else "Merge + save") }
                        Text(
                            (if (current != null) "Tick the versions to bring back." else "Tick two or more versions.") +
                                " Everything in your list now stays. You can change single entries later in the list itself.",
                            color = SecondaryText,
                            fontSize = 12.sp,
                        )
                    }
                }
            }
        }
    }
}

/** One version: the app that saved it and when, a tick, what it would bring back or drop against the list now, and [wipe]: it wiped the list ([ListVersionMerge.wasWipe]). */
@Composable
private fun VersionRow(
    kind: Int,
    v: ListVersionMerge.Opened,
    wipe: Boolean,
    current: ListVersionMerge.Opened?,
    picked: Boolean,
    onToggle: () -> Unit,
) {
    val problem = ListVersionMerge.pickProblem(v)
    ListRow(onClick = if (problem.isEmpty()) onToggle else null) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = picked, onCheckedChange = { onToggle() }, enabled = problem.isEmpty())
            Column(Modifier.weight(1f)) {
                Text(ListVersionText.title(v.v), color = PrimaryText, fontSize = 15.sp)
                val line = problem.ifEmpty { ListVersionMerge.deltaLine(kind, ListVersionMerge.deltaOf(v, current)) }
                val locked = if (problem.isEmpty() && v.locked) " · private part opens when you tick it" else ""
                Text(line + locked, color = SecondaryText, fontSize = 13.sp)
                if (wipe && !v.isEmpty) Text(ListVersionText.WIPED, color = Color(0xFFFF9500), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

internal fun entryCount(n: Int) = if (n == 1) "1 entry" else "$n entries"
