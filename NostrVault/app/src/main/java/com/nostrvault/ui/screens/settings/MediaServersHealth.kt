package com.nostrvault.ui.screens.settings

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nostrvault.relay.blossomUploadServer
import com.nostrvault.ui.screens.dashboard.CopyBlock
import com.nostrvault.ui.screens.dashboard.MediaCopyViewModel
import com.nostrvault.ui.screens.dashboard.MediaServer
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.ZapOrange
import kotlinx.coroutines.delay

/**
 * The parts of Media Servers ([BlossomSettingsScreen]) that read
 * [MediaCopyViewModel]: each server's health under its row, and "Your Media"
 * with Copy to servers. These were a second page under Vault Dashboard ›
 * Advanced (MediaServersPage) until this port of the iPhone's media settings
 * trim (Apple #1986): now the list, the health and the copy are one page.
 */
object MediaServersHealth {
    /**
     * The health to draw under a listed server, or null with the words to
     * say instead (iOS `server(configured:)` + `missingLine`). Uploads go to
     * [blossomUploadServer] of what was typed, so that is what was checked.
     */
    fun lookup(configured: String, saved: List<String>, servers: List<MediaServer>): Pair<MediaServer?, String> {
        if (configured !in saved) return null to "Not saved yet"
        val upload = blossomUploadServer(configured) ?: return null to "Not used: this server is gone"
        return servers.firstOrNull { it.url == upload } to "Not checked yet"
    }
}

/** One server's health, drawn under its address: a dot, what was found and when, and Test (iOS `ServerHealthLine`). */
@Composable
internal fun ServerHealthLine(server: MediaServer?, missing: String, onTest: () -> Unit) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(30_000)
            now = System.currentTimeMillis()
        }
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().padding(start = 48.dp, end = 16.dp, bottom = 10.dp),
    ) {
        Box(Modifier.size(8.dp).background(server?.health.dotColor(), CircleShape))
        Text(
            server?.let { serverStatusLine(it, now) } ?: missing,
            color = SecondaryText,
            fontSize = 12.sp,
            modifier = Modifier.weight(1f),
        )
        if (server != null) {
            // The spinner takes the button's place, so the row does not move.
            Box(contentAlignment = Alignment.Center) {
                if (server.health == MediaServer.Health.CHECKING) {
                    CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                } else {
                    TextButton(
                        onClick = onTest,
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                        modifier = Modifier.height(28.dp),
                    ) {
                        Text("Test", fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                            color = LocalNostrVaultColors.current.primaryText)
                    }
                }
            }
        }
    }
}

/** "Your Media": files stored here, how many some server is missing, and Copy to servers (iOS `MediaCopyRows`). */
@Composable
internal fun YourMediaSection(viewModel: MediaCopyViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var showFiles by remember { mutableStateOf(false) }
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "YOUR MEDIA",
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.sp,
            modifier = Modifier.padding(start = 16.dp, top = 24.dp, bottom = 8.dp),
        )
        Surface(
            color = SecondaryGroupedBg,
            shape = RoundedCornerShape(12.dp),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        ) {
            Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
                if (state.servers.isEmpty()) {
                    Text("Add a media server above to copy your files to it.", color = SecondaryText, fontSize = 13.sp)
                } else {
                    CopyBlock(
                        state = state,
                        showFiles = showFiles,
                        onToggleFiles = { showFiles = !showFiles },
                        onCopy = { showFiles = true; viewModel.startCopy() },
                        onStop = viewModel::stopCopy,
                        hostFor = viewModel::host,
                    )
                }
            }
        }
    }
}

private fun MediaServer.Health?.dotColor(): Color = when (this) {
    MediaServer.Health.WORKING -> SuccessGreen
    MediaServer.Health.ANSWERS, MediaServer.Health.LOST_FILE -> ZapOrange
    MediaServer.Health.OFFLINE -> ErrorRed
    MediaServer.Health.CHECKING, MediaServer.Health.UNKNOWN, null -> SecondaryText.copy(alpha = 0.4f)
}

/** "Has your files · checked 5 minutes ago": the iPhone's words for each state. */
internal fun serverStatusLine(server: MediaServer, now: Long): String {
    val state = when (server.health) {
        MediaServer.Health.CHECKING -> return "Checking…"
        MediaServer.Health.UNKNOWN -> return "Not checked yet"
        MediaServer.Health.WORKING -> "Has your files"
        MediaServer.Health.ANSWERS -> "Answers, but holds none of your files to check"
        MediaServer.Health.LOST_FILE -> "Answers, but a file it had is gone"
        MediaServer.Health.OFFLINE -> "Not answering"
    }
    val at = server.checkedAtMillis ?: return state
    val ago = if (now - at < 60_000) {
        "just now"
    } else {
        DateUtils.getRelativeTimeSpanString(at, now, DateUtils.MINUTE_IN_MILLIS).toString().lowercase()
    }
    return "$state · checked $ago"
}
