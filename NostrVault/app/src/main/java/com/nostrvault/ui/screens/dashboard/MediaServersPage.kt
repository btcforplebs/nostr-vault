package com.nostrvault.ui.screens.dashboard

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
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
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.ZapOrange
import kotlinx.coroutines.delay

/**
 * Vault Dashboard › Media servers (iOS `MediaServersPage`): your Blossom
 * servers, whether each answers, and the files on this phone that some server
 * does not have yet, with the one action that copies them. Replaces the old
 * Blossom dashboard (stats, pull/push and an activity log).
 */
@Composable
internal fun MediaServersPage(
    onBack: () -> Unit,
    onOpenSettings: () -> Unit,
    viewModel: MediaCopyViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var showFiles by remember { mutableStateOf(false) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(30_000)
            now = System.currentTimeMillis()
        }
    }

    Column(
        verticalArrangement = Arrangement.spacedBy(24.dp),
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
            .padding(bottom = 32.dp),
    ) {
        SheetPageHeader(title = "Media servers", onBack = onBack)
        DashSection(title = "Servers") {
            if (state.servers.isEmpty()) {
                Text(
                    "None set up. Add one in Media server settings.",
                    color = SecondaryText,
                    fontSize = 13.sp,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                )
            } else {
                state.servers.forEachIndexed { index, server ->
                    if (index > 0) DashDivider()
                    ServerRow(server, now) { viewModel.test(server.url) }
                }
            }
            DashDivider()
            SettingLink(Icons.Filled.Settings, "Media server settings", null, onClick = onOpenSettings)
        }
        if (state.servers.isNotEmpty()) {
            DashSection(title = "Your media") {
                Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
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
        Spacer(Modifier.height(0.dp))
    }
}

/** One Blossom server: status dot, host, what the check found and when, and Test. */
@Composable
private fun ServerRow(server: MediaServer, now: Long, onTest: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(30.dp)) {
            Box(Modifier.size(10.dp).background(server.health.dotColor(), CircleShape))
        }
        Column(
            verticalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier.weight(1f).semantics(mergeDescendants = true) {},
        ) {
            Text(
                server.host,
                color = PrimaryText,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(serverStatusLine(server, now), color = SecondaryText, fontSize = 12.sp)
        }
        // The spinner takes the button's place, so the row does not move.
        Box(contentAlignment = Alignment.Center) {
            if (server.health == MediaServer.Health.CHECKING) {
                CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            } else {
                RowButton(title = "Test", onClick = onTest)
            }
        }
    }
}

private fun MediaServer.Health.dotColor(): Color = when (this) {
    MediaServer.Health.WORKING -> SuccessGreen
    MediaServer.Health.ANSWERS, MediaServer.Health.LOST_FILE -> ZapOrange
    MediaServer.Health.OFFLINE -> ErrorRed
    MediaServer.Health.CHECKING, MediaServer.Health.UNKNOWN -> SecondaryText.copy(alpha = 0.4f)
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
