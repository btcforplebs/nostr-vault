package com.nostrvault.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.nostrvault.service.ZapsToday
import kotlinx.coroutines.withTimeoutOrNull
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * On this day: your own notes from this date one and two years ago, read
 * from your own vault; a tap opens the note. A small widget shows the first,
 * a wider one up to three (iOS: Your space's On this day panel, #1677).
 */
class OnThisDayWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        var snapshot = WidgetSnapshotStore.read(context)
        // Picked for another day (or never): ask the vault again first.
        if (snapshot.onThisDay.dayStart != ZapsToday.startOfDay(System.currentTimeMillis())) {
            withTimeoutOrNull(REFRESH_BUDGET_MS) {
                runCatching { HomeWidgetRefresher.from(context).refreshFromWidget(live = false) }
                    .onFailure(HomeWidgetRefresher::logFailure)
            }
            snapshot = WidgetSnapshotStore.read(context)
        }
        val today = ZapsToday.startOfDay(System.currentTimeMillis())
        // Yesterday's picks are not "on this day": drawn as not loaded yet.
        val day = snapshot.onThisDay.takeIf { it.dayStart == today } ?: VaultSnapshot.OnThisDay()
        provideContent { GlanceTheme { OnThisDayContent(context, day) } }
    }

    companion object {
        private const val REFRESH_BUDGET_MS = 15_000L
    }
}

class OnThisDayReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = OnThisDayWidget()
}

@Composable
private fun OnThisDayContent(context: Context, day: VaultSnapshot.OnThisDay) {
    val wide = LocalSize.current.width >= 200.dp
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.Background)
            .padding(12.dp)
            .clickable(openApp(context, "feed")),
    ) {
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("On this day", style = WidgetTheme.Title, maxLines = 1)
            Spacer(GlanceModifier.defaultWeight())
            Text(LocalDate.now().format(DateTimeFormatter.ofPattern("MMM d", Locale.getDefault())), style = WidgetTheme.Caption, maxLines = 1)
        }
        Spacer(GlanceModifier.height(8.dp))
        val notes = day.notes
        when {
            day.dayStart <= 0L -> Text("Open Nostr Vault to look back", style = WidgetTheme.Caption)
            notes.isEmpty() -> Text("Nothing from this day in past years.", style = WidgetTheme.Caption)
            !wide -> DayRow(context, notes.first(), bodyLines = 4)
            else -> notes.take(OnThisDayRules.MAX_ROWS).forEachIndexed { i, n ->
                if (i > 0) Spacer(GlanceModifier.height(7.dp))
                DayRow(context, n, bodyLines = 1)
            }
        }
    }
}

@Composable
private fun DayRow(context: Context, note: VaultSnapshot.DayNote, bodyLines: Int) {
    Column(modifier = GlanceModifier.fillMaxWidth().clickable(openApp(context, "note/${note.id}"))) {
        Text(
            OnThisDayRules.yearsText(note.yearsAgo),
            maxLines = 1,
            style = TextStyle(color = ColorProvider(WidgetTheme.Accent), fontSize = 11.sp, fontWeight = FontWeight.Medium),
        )
        Text(
            note.text,
            maxLines = bodyLines,
            style = TextStyle(color = ColorProvider(WidgetTheme.Primary), fontSize = 12.sp),
        )
    }
}
