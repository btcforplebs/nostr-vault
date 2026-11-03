package com.nostrvault.ui.screens.shareportal

import android.content.Context
import android.text.format.Formatter
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.NostrService
import com.nostrvault.service.shareportal.PagePdfRenderer
import com.nostrvault.service.shareportal.PrivateCopyService
import com.nostrvault.service.shareportal.handlers.PrivateCopyRecord
import com.nostrvault.shareportal.ShareClassifier
import com.nostrvault.shareportal.ShareInput
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.shareportal.ShareQueue
import com.nostrvault.ui.theme.SecondaryText
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * Review card for a private copy: what will be kept (the shared file, or the
 * page as a PDF), and an explicit Save privately. Sealed on this device with
 * a new key and kept only in this device's vault. Twin: PrivateCopyReviewView.swift.
 */
@Composable
internal fun PrivateCopyReviewContent(
    intent: ShareIntent,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onDone: () -> Unit,
    onDismiss: () -> Unit,
    viewModel: PrivateCopyReviewViewModel = hiltViewModel(key = "private-copy-${intent.id}"),
) {
    val busy by viewModel.busy.collectAsState()
    val status by viewModel.status.collectAsState()
    val error by viewModel.error.collectAsState()
    val saved by viewModel.saved.collectAsState()
    var showCopies by remember(intent.id) { mutableStateOf(false) }
    val context = LocalContext.current
    if (showCopies) {
        PrivateCopiesScreen(onBack = { showCopies = false })
        return
    }
    val file = remember(intent.id) { intent.files.firstOrNull() }
    val url = remember(intent.id) { viewModel.pageUrl(intent) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Keep a private copy", style = MaterialTheme.typography.titleMedium)
        if (saved) {
            Text("Saved privately.", style = MaterialTheme.typography.bodyLarge)
            Text("Only you can open it, from your accounts' keys.", color = SecondaryText)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = onDone) { Text("Done") }
                OutlinedButton(onClick = { showCopies = true }) { Text("See private copies") }
            }
            return@Column
        }
        when {
            file != null -> {
                Text(file.name, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(Formatter.formatShortFileSize(context, file.bytes), color = SecondaryText)
                if (intent.files.size > 1) Text("Only the first file is kept.", color = SecondaryText)
            }
            url != null -> {
                Text("This page is saved as a PDF.")
                (intent.source.title ?: url).let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis, color = SecondaryText) }
            }
            else -> Text("Nothing to keep: no file or web page came with this share.", color = MaterialTheme.colorScheme.error)
        }
        Text(
            "Encrypted on this device with a new key. Kept only in your vault, never on outside servers.",
            color = SecondaryText,
            style = MaterialTheme.typography.bodySmall,
        )
        val wanted = intent.account
        if (wanted != null && needsSwitch) {
            Text("This was shared for another of your accounts.", color = SecondaryText)
            OutlinedButton(onClick = { onSwitchAccount(wanted) }, enabled = !busy) { Text("Switch to that account") }
        }
        status?.takeIf { busy }?.let { Text(it, color = SecondaryText) }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = { viewModel.save(intent) },
                enabled = !busy && !needsSwitch && (file != null || url != null),
            ) { Text(if (busy) "Saving…" else "Save privately") }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }
    }
}

@HiltViewModel
class PrivateCopyReviewViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val service: PrivateCopyService,
    private val nostrService: NostrService,
) : ViewModel() {
    private val queue = ShareQueue.forApp(context)

    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()
    private val _status = MutableStateFlow<String?>(null)
    val status = _status.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()
    private val _saved = MutableStateFlow(false)
    val saved = _saved.asStateFlow()

    /** The web page a link-only share points at. */
    fun pageUrl(intent: ShareIntent): String? =
        ShareClassifier.webUrl(ShareInput(url = intent.source.url, text = intent.source.text))

    fun save(intent: ShareIntent) {
        if (_busy.value) return
        val lock = nostrService.lockPostingAccount()
        if (intent.account != null && intent.account != lock.npub) {
            _error.value = "Switch to that account first."
            return
        }
        _busy.value = true
        _error.value = null
        viewModelScope.launch {
            try {
                val problem = saveNow(intent, lock)
                if (problem == null) {
                    // Saved: the claimed share goes now, so leaving the card can't save it twice.
                    withContext(Dispatchers.IO) { queue.finish(intent.id) }
                    _saved.value = true
                } else {
                    _error.value = problem
                }
            } finally {
                _busy.value = false
                _status.value = null
            }
        }
    }

    private suspend fun saveNow(intent: ShareIntent, lock: com.nostrvault.data.model.PostingAccount.Lock): String? {
        val shared = intent.files.firstOrNull()
        val (bytes, name, mime) = if (shared != null) {
            val file = queue.claimedFile(intent, shared)?.takeIf { it.isFile } ?: return "The shared file is missing."
            if (file.length() > PrivateCopyRecord.MAX_BYTES) return PrivateCopyService.TOO_BIG
            Triple(withContext(Dispatchers.IO) { file.readBytes() }, shared.name, shared.mime)
        } else {
            val url = pageUrl(intent) ?: return "Nothing to keep."
            _status.value = "Saving the page as a PDF…"
            val pdf = PagePdfRenderer.render(context, url) ?: return "Couldn't load that page to save it."
            Triple(pdf, pdfName(intent.source.title), "application/pdf")
        }
        _status.value = "Encrypting and saving…"
        return service.save(bytes, name, mime, pageUrl(intent), intent.source.title, lock)
    }

    /** A file name from the page title: safe characters only, `.pdf` on the end. */
    private fun pdfName(title: String?): String {
        val base = title.orEmpty().replace(Regex("[^\\p{L}\\p{N} ._-]"), "").trim().trimStart('.').take(80)
        return (base.ifEmpty { "page" }) + ".pdf"
    }
}
