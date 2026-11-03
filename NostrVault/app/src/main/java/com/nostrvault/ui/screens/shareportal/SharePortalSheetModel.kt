package com.nostrvault.ui.screens.shareportal

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.nostrvault.shareportal.ShareAccountsSnapshot
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareActionAvailability
import com.nostrvault.shareportal.ShareClassifier
import com.nostrvault.shareportal.ShareInputReader
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.shareportal.ShareSource

/** The share sheet's state: what was shared, the action picked, and how sending went. */
class SharePortalSheetModel(private val draftId: String) {
    sealed interface Phase {
        data object Loading : Phase
        data object Pick : Phase
        data class Form(val action: ShareAction) : Phase
        data object Sending : Phase
        data object Sent : Phase
        data object Failed : Phase
    }

    var phase by mutableStateOf<Phase>(Phase.Loading)
        private set
    var read by mutableStateOf<ShareInputReader.Read?>(null)
        private set
    var actions by mutableStateOf<List<ShareAction>>(emptyList())
        private set
    var accounts by mutableStateOf<ShareAccountsSnapshot?>(null)
        private set
    /** Which account the intent is for; the snapshot's active one unless changed. */
    var account by mutableStateOf<String?>(null)

    fun load(read: ShareInputReader.Read?, accounts: ShareAccountsSnapshot?) {
        this.read = read
        this.accounts = accounts
        account = accounts?.active
        actions = read?.let { ShareActionAvailability.available(ShareClassifier.classify(it.input)) }.orEmpty()
        phase = Phase.Pick
    }

    fun pick(action: ShareAction) { phase = Phase.Form(action) }
    fun back() { phase = Phase.Pick }

    /** The intent to queue for [action] with [form]. */
    fun intent(action: ShareAction, form: Map<String, String>, nowSeconds: Long = System.currentTimeMillis() / 1000): ShareIntent? {
        val r = read ?: return null
        val input = r.input
        return ShareIntent(
            id = draftId,
            createdAt = nowSeconds,
            action = action,
            account = account?.takeIf { it.startsWith("npub1") },
            source = ShareSource(
                url = input.url ?: ShareClassifier.webUrl(input),
                title = input.title,
                text = input.text,
                selection = input.selection,
                app = r.app,
                ldTypes = input.ldTypes,
            ),
            files = r.files,
            form = form.mapValues { ShareIntent.cap(it.value, ShareIntent.MAX_FORM_VALUE) },
        )
    }

    fun sending() { phase = Phase.Sending }
    fun sent(ok: Boolean) { phase = if (ok) Phase.Sent else Phase.Failed }
}
