package com.nostrvault.ui.screens.shareportal

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.lifecycle.lifecycleScope
import com.nostrvault.shareportal.ShareAccountsSnapshot
import com.nostrvault.shareportal.ShareInputReader
import com.nostrvault.shareportal.ShareQueue
import com.nostrvault.ui.theme.NostrVaultTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

/**
 * "Share → Nostr Vault" for links, text and files (photos and videos still go
 * to MainActivity until phase 3). Twin: the iOS share extension.
 *
 * Exported, so every extra is another app's input: [ShareInputReader] reads it
 * defensively, and this activity never signs, publishes or talks to a relay —
 * it imports nothing of the signer, NostrService or the config. It writes a
 * [com.nostrvault.shareportal.ShareIntent] to the [ShareQueue] and either
 * leaves or, on Open now, starts the app at `nostrvault://shareportal`, where
 * the review card does the rest after an explicit tap.
 */
class SharePortalActivity : ComponentActivity() {

    private val draftId = UUID.randomUUID().toString()
    private var sent = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val queue = ShareQueue.forApp(this)
        val model = SharePortalSheetModel(draftId)
        val shared = intent
        val app = referrer?.host
        setContent {
            NostrVaultTheme {
                SharePortalSheet(
                    model = model,
                    onSend = { intent ->
                        lifecycleScope.launch {
                            val ok = withContext(Dispatchers.IO) { queue.commit(intent) }
                            sent = ok
                            model.sent(ok)
                        }
                    },
                    onOpenNow = { openApp() },
                    onClose = { finish() },
                )
            }
        }
        lifecycleScope.launch {
            // The read grant on a shared stream lasts only while this activity
            // lives, so files are copied into the queue straight away.
            val read = withContext(Dispatchers.IO) {
                runCatching { ShareInputReader.read(this@SharePortalActivity, shared, draftId, queue, app) }.getOrNull()
            }
            val accounts = withContext(Dispatchers.IO) {
                ShareAccountsSnapshot.read(ShareAccountsSnapshot.file(this@SharePortalActivity))
            }
            model.load(read, accounts)
        }
    }

    override fun onDestroy() {
        // Files copied for a draft that was never sent are not kept.
        if (!sent && isFinishing) ShareQueue.forApp(this).discardStaged(draftId)
        super.onDestroy()
    }

    private fun openApp() {
        val open = Intent(Intent.ACTION_VIEW, Uri.parse(SHARE_PORTAL_LINK)).apply {
            setPackage(packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching { startActivity(open) }
        finish()
    }

    companion object {
        const val SHARE_PORTAL_LINK = "nostrvault://shareportal"
    }
}
