package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.WotZombies
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.screens.dashboard.DashDivider
import com.nostrvault.ui.screens.dashboard.DashSection
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat

/**
 * The vault's zombie check (`WotZombiesC`) for the active account: started
 * when My Web opens, polled while it runs, reused for a day by the vault.
 * Read-only: nothing here signs or unfollows (iOS `WotZombiesStore`).
 */
@Stable
internal object WotZombiesStore {
    var state by mutableStateOf<WotZombies.State?>(null)
        private set
    private var owner = ""
    private var polling: Job? by mutableStateOf(null)

    /** Test seams: where the vault is read, and what it answers for (owner, force). */
    internal var io: CoroutineDispatcher = Dispatchers.IO
    internal var read: (String, Boolean) -> WotZombies.State? = { owner, force ->
        WotZombies.parse(HavenBridge.wotZombies(owner, force))
    }

    /** The report as it stands now: only people still followed. */
    fun report(following: Set<String>): WotZombies.Report? {
        val report = state?.report?.takeIf { it.owner == owner } ?: return null
        // An empty set means not loaded yet, not "follows nobody".
        return if (following.isEmpty()) report else report.keeping(following)
    }

    val checking: Boolean get() = state?.checking ?: (polling != null)

    fun load(scope: CoroutineScope, account: String, force: Boolean = false) {
        if (account != owner) {
            owner = account
            state = null
        }
        if (account.isEmpty()) return
        polling?.cancel()
        polling = scope.launch {
            var forceNext = force
            // A check on ~1,000 follows took ~40 s in the dry run; stop polling
            // after 3 minutes, the next open asks again.
            repeat(90) {
                val next = withContext(io) { read(account, forceNext) }
                forceNext = false
                if (!isActive || account != owner) return@launch
                state = next
                if (next?.checking != true) {
                    polling = null
                    return@launch
                }
                delay(2_000)
            }
            polling = null
        }
    }

    internal fun resetForTest() {
        polling?.cancel()
        polling = null
        state = null
        owner = ""
    }
}

internal val WotZombies.Bucket.color: Color
    get() = when (this) {
        WotZombies.Bucket.FRESH -> Color(0xFFFFCC00)
        WotZombies.Bucket.ROTTING -> Color(0xFFFF9500)
        WotZombies.Bucket.ANCIENT -> Color(0xFFFF3B30)
    }

/**
 * My Web's zombie card: the count, the three buckets, the way into the list,
 * and the button to Plebs vs. Zombies. Read-only (iOS `WotZombiesCard`).
 */
@Composable
internal fun WotZombiesCard(me: String, follows: Set<String>, onOpenList: () -> Unit) {
    val scope = rememberCoroutineScope()
    LaunchedEffect(me) { WotZombiesStore.load(scope, me) }
    val report = WotZombiesStore.report(follows)
    val error = WotZombiesStore.state?.error
    DashSection(title = "Zombies in your web") {
        when {
            report != null -> {
                val any = report.zombies.isNotEmpty()
                Headline(report, any, onOpenList)
                if (any) {
                    DashDivider()
                    Buckets(report)
                    Box(Modifier.padding(start = 14.dp, end = 14.dp, bottom = 14.dp)) { PlebsVsZombiesButton() }
                }
            }
            error != null && !WotZombiesStore.checking -> Status(
                if (error == "relay not running") "Shows once your vault is running"
                else "Zombies show for an account on this vault",
            )
            else -> Status("Checking who's been quiet…", spinning = true)
        }
    }
}

@Composable
private fun Headline(report: WotZombies.Report, any: Boolean, onOpenList: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = any, role = Role.Button, onClickLabel = "List them, quiet longest first", onClick = onOpenList)
            .semantics(mergeDescendants = true) {}
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        ZombieIcon()
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(WotZombies.headline(report.zombies.size, report.follows), color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text("Nothing signed by them in that time", color = SecondaryText, fontSize = 13.sp)
        }
        if (any) Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(14.dp))
    }
}

@Composable
private fun Buckets(report: WotZombies.Report) {
    val format = NumberFormat.getIntegerInstance()
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
        WotZombies.Bucket.entries.forEachIndexed { index, bucket ->
            if (index > 0) VerticalDivider(Modifier.height(44.dp))
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.weight(1f).semantics(mergeDescendants = true) {},
            ) {
                Text(format.format(report.count(bucket)), color = bucket.color, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Text(bucket.title, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text(bucket.daysText, color = SecondaryText, fontSize = 12.sp)
            }
        }
    }
}

@Composable
private fun Status(text: String, spinning: Boolean = false) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        ZombieIcon()
        Text(text, color = SecondaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        if (spinning) CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
    }
}

/** The card's icon: 🧟 (Plebs vs. Zombies' own, with their OK). */
@Composable
internal fun ZombieIcon() {
    val primary = LocalNostrVaultColors.current.primary
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(40.dp)
            .background(primary.copy(alpha = 0.14f), RoundedCornerShape(10.dp))
            .clearAndSetSemantics {},
    ) {
        Text("🧟", fontSize = 22.sp, textAlign = TextAlign.Center)
    }
}

/**
 * Opens Plebs vs. Zombies in the browser, where the owner cleans up. The app
 * itself never unfollows anyone for this (Logen 2026-11-01).
 */
@Composable
internal fun PlebsVsZombiesButton(modifier: Modifier = Modifier) {
    val uriHandler = LocalUriHandler.current
    Button(
        onClick = { runCatching { uriHandler.openUri(WotZombies.PLEBS_VS_ZOMBIES_URL) } },
        colors = ButtonDefaults.buttonColors(containerColor = LocalNostrVaultColors.current.primary, contentColor = PrimaryText),
        modifier = modifier
            .fillMaxWidth()
            .semantics { contentDescription = "Clean up on Plebs vs Zombies, opens plebsvszombies.cc in your browser" },
    ) {
        Text("Clean up on Plebs vs Zombies", fontSize = 16.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(vertical = 4.dp))
    }
}
