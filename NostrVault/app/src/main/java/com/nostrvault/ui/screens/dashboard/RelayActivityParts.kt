package com.nostrvault.ui.screens.dashboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Error
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.BuildConfig
import com.nostrvault.relay.PlainLog
import com.nostrvault.ui.theme.*
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// Shared pieces for the plain-language relay console: the dashboard card and
// the Relay Activity screen. The raw log stays in Settings › Logs
// (LogViewerScreen). Copy and Export only ever hand out PlainLog.exportText,
// which is built from the translated items and scrubbed of keys, ids, IPs
// and paths.

internal val PlainLog.Severity.icon: ImageVector
    get() = when (this) {
        PlainLog.Severity.GOOD -> NostrVaultIcons.CheckCircle
        PlainLog.Severity.HEADS_UP -> NostrVaultIcons.Alert
        PlainLog.Severity.PROBLEM -> Icons.Filled.Error
    }

internal val PlainLog.Severity.tint: Color
    get() = when (this) {
        PlainLog.Severity.GOOD -> SuccessGreen
        PlainLog.Severity.HEADS_UP -> ZapOrange
        PlainLog.Severity.PROBLEM -> ErrorRed
    }

internal val PlainLog.Severity.summary: String
    get() = when (this) {
        PlainLog.Severity.GOOD -> "Everything looks fine"
        PlainLog.Severity.HEADS_UP -> "Working, with a few hiccups"
        PlainLog.Severity.PROBLEM -> "Something needs your attention"
    }

/** Status pill: the worst thing since the relay last came up. */
@Composable
internal fun RelayHealthPill(health: PlainLog.Severity) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .background(health.tint.copy(alpha = 0.14f), RoundedCornerShape(50))
            .padding(horizontal = 7.dp, vertical = 3.dp)
            .clearAndSetSemantics { contentDescription = "Relay status: ${health.label}" },
    ) {
        Icon(health.icon, contentDescription = null, tint = health.tint, modifier = Modifier.size(11.dp))
        Spacer(Modifier.width(4.dp))
        Text(health.label, color = health.tint, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** One translated item. `compact` is the dashboard card. */
@Composable
internal fun RelayActivityRow(item: PlainLog.Item, compact: Boolean = false) {
    val hint = item.hint?.takeIf { item.severity != PlainLog.Severity.GOOD }
    val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(item.lastSeen)
    val description = buildString {
        append("${item.severity.label}: ${item.title}")
        if (item.count > 1) append(". ${item.count} times")
        if (hint != null) append(". $hint")
    }

    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = if (compact) 10.dp else 16.dp, vertical = if (compact) 6.dp else 9.dp)
            .clearAndSetSemantics { contentDescription = description },
    ) {
        Icon(
            item.severity.icon,
            contentDescription = null,
            tint = item.severity.tint,
            modifier = Modifier.padding(top = 1.dp).size(if (compact) 14.dp else 18.dp),
        )
        Spacer(Modifier.width(if (compact) 8.dp else 10.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = item.title,
                    color = PrimaryText,
                    fontSize = if (compact) 12.sp else 15.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = if (compact) 1 else 3,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (item.count > 1) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = "×${item.count}",
                        color = SecondaryText,
                        fontSize = if (compact) 10.sp else 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier
                            .background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(50))
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                }
                Spacer(Modifier.weight(1f).widthIn(min = 4.dp))
                Text(time, color = SecondaryText, fontSize = if (compact) 10.sp else 11.sp)
            }
            if (hint != null) {
                Text(
                    text = hint,
                    color = SecondaryText,
                    fontSize = if (compact) 11.sp else 13.sp,
                    maxLines = if (compact) 1 else Int.MAX_VALUE,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** Empty state shared by the card and the screen. */
@Composable
internal fun RelayActivityEmpty(compact: Boolean = false, modifier: Modifier = Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = modifier.fillMaxWidth().padding(16.dp),
    ) {
        Text(
            "Nothing to report yet",
            color = SecondaryText,
            fontSize = if (compact) 12.sp else 16.sp,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            "Relay activity and any problems will show up here.",
            color = TertiaryText,
            fontSize = if (compact) 11.sp else 12.sp,
        )
    }
}

/** States what Copy/Export leave out, so people know a report is safe to share. */
@Composable
internal fun RelayPrivacyNote(modifier: Modifier = Modifier) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        Icon(NostrVaultIcons.Lock, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(6.dp))
        Text("Copies leave out keys, IDs, IP addresses and file paths.", color = SecondaryText, fontSize = 11.sp)
    }
}

/** The text Copy and Export hand out: app version and OS on top, then the scrubbed items. */
internal object RelayActivityReport {
    fun text(items: List<PlainLog.Item>): String = PlainLog.exportText(
        items,
        header = listOf(
            "App: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
            "System: Android ${Build.VERSION.RELEASE}",
        ),
    )

    fun fileName(now: Date = Date()): String =
        "nostr-vault-relay-report-${SimpleDateFormat("yyyy-MM-dd-HHmm", Locale.US).format(now)}.txt"

    fun copy(context: Context, items: List<PlainLog.Item>) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Relay report", text(items)))
    }
}
