package com.nostrvault.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.datastore.preferences.core.Preferences
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.ZapsToday
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

// ── Vault glance ───────────────────────────────────────────────────────

/**
 * What the one-cell widget shows: the Android stand-in for the iPhone Lock
 * Screen widget (iOS `LockMetric`), which shows one number from the vault.
 * Phones have no lock-screen slot, so it is the smallest home-screen widget
 * instead.
 */
enum class GlanceMetric(
    /** In the picker. */
    val pickerName: String,
    /** The `nostrvault://` destination a tap opens (iOS `LockScreenView.link`). */
    val destination: String,
) {
    RELAY("Vault status", "relay"),
    MENTIONS("Mentions", "mentions"),
    DMS("Unread messages", "dms"),
    EVENTS("Events stored", "relay"),
    ZAPS("Zaps today", "wallet");

    companion object {
        const val KEY = "glance.metric"
        val DEFAULT = RELAY

        /** An unset or stale choice falls back on the vault status. */
        fun from(get: (String) -> String?): GlanceMetric =
            entries.firstOrNull { it.name == get(KEY) } ?: DEFAULT

        fun toEntries(metric: GlanceMetric): Map<String, String> = mapOf(KEY to metric.name)
    }
}

/** The widget's two lines, and whether its dot shows the vault as up. */
data class GlanceReading(val value: String, val label: String, val live: Boolean? = null)

/**
 * [metric] read off [snapshot], in iOS `LockScreenView`'s words: "Live" or
 * "Off" for the vault, otherwise a count. Mentions count the snapshot's list,
 * which holds at most a widget's worth. Zaps count only for [account] (the
 * active account's hex pubkey) and the day that started at [todayStart]
 * (local midnight, epoch seconds), so yesterday's number never shows after
 * midnight, and another account's never shows after a switch whose 0 didn't
 * reach the file (a failed write, or the process dying first).
 */
fun glanceReading(
    metric: GlanceMetric,
    snapshot: VaultSnapshot,
    account: String,
    todayStart: Long = ZapsToday.startOfDay(System.currentTimeMillis()),
): GlanceReading = when (metric) {
    GlanceMetric.RELAY -> GlanceReading(if (snapshot.relay.running) "Live" else "Off", "vault", live = snapshot.relay.running)
    GlanceMetric.MENTIONS -> GlanceReading("${snapshot.mentions.size}", "mentions")
    GlanceMetric.DMS -> GlanceReading("${snapshot.unreadDMs}", "messages")
    GlanceMetric.EVENTS -> GlanceReading(compactCount(snapshot.relay.eventsStored), "events")
    GlanceMetric.ZAPS -> GlanceReading(compactCount(zapsFor(snapshot.zapsToday, account, todayStart)), "zaps today")
}

/**
 * [zaps] when they were counted for [account]; 0 for anyone else, as for
 * another day. An [account] of "" is unknown, not a mismatch: the widget's
 * 30-minute redraw runs in a fresh process before anything has loaded the
 * config, and the file is then the best word on whose count it holds.
 */
private fun zapsFor(zaps: VaultSnapshot.ZapCount, account: String, todayStart: Long): Int =
    if (account.isEmpty() || zaps.account == account) zaps.on(todayStart) else 0

/** 950, 1.2k, 34k, 1.2M: a count that fits one cell. iOS `NV.compactCount`. */
fun compactCount(n: Int): String = when {
    n < 1_000 -> "$n"
    n < 10_000 -> trimmed(n / 1_000.0) + "k"
    n < 1_000_000 -> "${n / 1_000}k"
    n < 10_000_000 -> trimmed(n / 1_000_000.0) + "M"
    else -> "${n / 1_000_000}M"
}

/** One decimal, dropped when it is zero ("1.2", "3"). Rounds down, so 9,999 is never "10.0k". */
private fun trimmed(x: Double): String {
    val tenths = (x * 10).toInt()
    return if (tenths % 10 == 0) "${tenths / 10}" else "${tenths / 10}.${tenths % 10}"
}

class VaultGlanceWidget : GlanceAppWidget() {
    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface GlanceEntryPoint {
        fun configStore(): ConfigStore
    }

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetSnapshotStore.read(context)
        // "" before anything has loaded the config (the periodic redraw in a
        // fresh process): the file's count is trusted then. Not reload() here:
        // it does JNI and keystore reads, and can save.
        val account = EntryPointAccessors
            .fromApplication(context.applicationContext, GlanceEntryPoint::class.java)
            .configStore()
            .activeAccountHexPubkey.value
        provideContent {
            GlanceTheme {
                val metric = GlanceMetric.from(currentState<Preferences>().asLookup())
                GlanceContent(context, metric, glanceReading(metric, snapshot, account))
            }
        }
    }
}

class VaultGlanceReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = VaultGlanceWidget()
}

/**
 * One cell: the number, large, over its label. The vault status adds a dot,
 * green while live and grey when off, since the word alone is small. A tap
 * opens the screen the number is about.
 */
@Composable
private fun GlanceContent(context: Context, metric: GlanceMetric, reading: GlanceReading) {
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.Background)
            .cornerRadius(16.dp)
            .padding(6.dp)
            .clickable(openApp(context, metric.destination)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (reading.live != null) {
                Box(
                    modifier = GlanceModifier
                        .size(8.dp)
                        .background(if (reading.live) LIVE else OFF)
                        .cornerRadius(4.dp),
                ) {}
                Spacer(GlanceModifier.width(4.dp))
            }
            Text(
                reading.value,
                maxLines = 1,
                style = TextStyle(
                    color = ColorProvider(if (reading.live == false) WidgetTheme.Secondary else WidgetTheme.Accent),
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
        }
        Text(reading.label, maxLines = 1, style = WidgetTheme.Caption)
    }
}

private val LIVE = Color(0xFF34C759)
private val OFF = Color(0xFF8E8E93)
