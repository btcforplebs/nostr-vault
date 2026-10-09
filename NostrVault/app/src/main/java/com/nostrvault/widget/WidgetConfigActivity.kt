package com.nostrvault.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.glance.GlanceId
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.getAppWidgetState
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.lifecycle.lifecycleScope
import com.nostrvault.ui.theme.NostrVaultTheme
import com.nostrvault.ui.theme.Surface0
import kotlinx.coroutines.launch

/**
 * The settings sheet for a home-screen widget — Android's counterpart to the
 * options iOS shows when you edit a widget (QuickActionsIntent,
 * FeedGlanceIntent, MosaicIntent).
 *
 * One activity serves every configurable widget; which form it shows comes
 * from the provider the widget id belongs to. The launcher opens it from the
 * widget's "reconfigure" option; on Android 12+ a new widget is placed with
 * the defaults and this is optional, before that it opens on placement.
 * Choices are written to the widget's own Glance state, so two Feed widgets
 * can show Following and Mentions side by side.
 */
class WidgetConfigActivity : ComponentActivity() {

    private enum class Kind { QUICK_ACTIONS, FEED, MOSAIC }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val appWidgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

        // Backing out must not leave a half-placed widget behind (pre-12 the
        // launcher removes a widget whose configure step was cancelled).
        setResult(RESULT_CANCELED, resultIntent(appWidgetId))
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return finish()

        val provider = AppWidgetManager.getInstance(this).getAppWidgetInfo(appWidgetId)?.provider?.className
        val kind = when (provider) {
            QuickActionsReceiver::class.java.name -> Kind.QUICK_ACTIONS
            FeedReceiver::class.java.name -> Kind.FEED
            MosaicReceiver::class.java.name -> Kind.MOSAIC
            else -> return finish()
        }
        val glanceId = GlanceAppWidgetManager(this).getGlanceIdBy(appWidgetId)

        lifecycleScope.launch {
            val prefs = getAppWidgetState(this@WidgetConfigActivity, PreferencesGlanceStateDefinition, glanceId)
            val current = prefs.asLookup()
            enableEdgeToEdge()
            setContent {
                NostrVaultTheme(oledMode = true) {
                    Surface(modifier = Modifier.fillMaxSize(), color = Surface0) {
                        Column(
                            modifier = Modifier
                                .safeDrawingPadding()
                                .verticalScroll(rememberScrollState())
                                .padding(20.dp),
                        ) {
                            when (kind) {
                                Kind.QUICK_ACTIONS -> QuickActionsForm(QuickActionsConfig.from(current)) {
                                    save(appWidgetId, glanceId, QuickActionsWidget(), it.toEntries())
                                }
                                Kind.FEED -> FeedForm(FeedConfig.from(current)) {
                                    save(appWidgetId, glanceId, FeedWidget(), it.toEntries())
                                }
                                Kind.MOSAIC -> MosaicForm(MosaicConfig.from(current)) {
                                    save(appWidgetId, glanceId, MosaicWidget(), it.toEntries())
                                }
                            }
                            Spacer(Modifier.height(12.dp))
                            TextButton(onClick = { finish() }) { Text("Cancel") }
                        }
                    }
                }
            }
        }
    }

    private fun save(appWidgetId: Int, glanceId: GlanceId, widget: GlanceAppWidget, entries: Map<String, String>) {
        lifecycleScope.launch {
            updateAppWidgetState(this@WidgetConfigActivity, glanceId) { prefs ->
                entries.forEach { (key, value) -> prefs[stringPreferencesKey(key)] = value }
            }
            widget.update(this@WidgetConfigActivity, glanceId)
            setResult(RESULT_OK, resultIntent(appWidgetId))
            finish()
        }
    }

    private fun resultIntent(appWidgetId: Int) =
        Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
}

@Composable
private fun QuickActionsForm(initial: QuickActionsConfig, onSave: (QuickActionsConfig) -> Unit) {
    var slots by remember { mutableStateOf(initial.slots) }
    Title("Quick Actions", "Tiles that open straight into the screen you want. A narrow widget shows the first two.")
    listOf("First", "Second", "Third", "Fourth").forEachIndexed { i, name ->
        Section(name)
        QuickAction.entries.forEach { action ->
            Choice(action.pickerName, selected = slots[i] == action) {
                slots = slots.toMutableList().also { it[i] = action }
            }
        }
    }
    SaveButton { onSave(QuickActionsConfig(slots)) }
}

@Composable
private fun FeedForm(initial: FeedConfig, onSave: (FeedConfig) -> Unit) {
    var config by remember { mutableStateOf(initial) }
    Title("Feed", "Recent notes from your feed or your mentions.")
    Section("Source")
    FeedSource.entries.forEach { source ->
        Choice(source.label, selected = config.source == source) { config = config.copy(source = source) }
    }
    Section("Density")
    FeedDensity.entries.forEach { density ->
        Choice(density.label, selected = config.density == density) { config = config.copy(density = density) }
    }
    Toggle("Show avatars", config.showAvatars) { config = config.copy(showAvatars = it) }
    SaveButton { onSave(config) }
}

@Composable
private fun MosaicForm(initial: MosaicConfig, onSave: (MosaicConfig) -> Unit) {
    var config by remember { mutableStateOf(initial) }
    Title("Mosaic", "Your Blossom media, live on the home screen.")
    Section("Layout")
    MosaicStyle.entries.forEach { style ->
        Choice(style.label, selected = config.style == style) { config = config.copy(style = style) }
    }
    Toggle("Rounded tiles", config.rounded) { config = config.copy(rounded = it) }
    SaveButton { onSave(config) }
}

@Composable
private fun Title(title: String, subtitle: String) {
    Text(title, style = MaterialTheme.typography.headlineSmall)
    Spacer(Modifier.height(4.dp))
    Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun Section(name: String) {
    Spacer(Modifier.height(16.dp))
    Text(name, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun Choice(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onClick)
        Text(label)
    }
}

@Composable
private fun Toggle(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Spacer(Modifier.height(16.dp))
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onChange(!checked) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label)
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun SaveButton(onClick: () -> Unit) {
    Spacer(Modifier.height(24.dp))
    Button(onClick = onClick, modifier = Modifier.fillMaxWidth()) { Text("Save") }
}
