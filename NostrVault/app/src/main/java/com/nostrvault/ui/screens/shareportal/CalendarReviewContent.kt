package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.service.shareportal.CalendarEditFields
import com.nostrvault.service.shareportal.CalendarShareParser
import com.nostrvault.service.shareportal.handlers.CalendarShareHandler
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.theme.SecondaryText
import java.io.File
import java.time.ZoneId

/**
 * Event → calendar (NIP-52): what the `.ics` or the page said, all editable,
 * then Publish. Needs a start. Twin: CalendarReviewView.swift.
 */
@Composable
internal fun CalendarReviewContent(
    intent: ShareIntent,
    handler: CalendarShareHandler,
    busy: Boolean,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onDismiss: () -> Unit,
    icsFile: File?,
    onPublish: (CalendarShareParser.Event) -> Unit,
) {
    val device = remember { ZoneId.systemDefault() }
    var loaded by remember(intent.id) { mutableStateOf<CalendarShareParser.Event?>(null) }
    var title by remember(intent.id) { mutableStateOf("") }
    var allDay by remember(intent.id) { mutableStateOf(false) }
    var start by remember(intent.id) { mutableStateOf("") }
    var end by remember(intent.id) { mutableStateOf("") }
    var location by remember(intent.id) { mutableStateOf("") }
    var description by remember(intent.id) { mutableStateOf("") }
    LaunchedEffect(intent.id) {
        val ev = handler.load(intent, icsFile)
        title = ev.title.ifEmpty { intent.source.title.orEmpty() }
        allDay = ev.allDay
        start = CalendarEditFields.startText(ev, device)
        end = CalendarEditFields.endText(ev, device)
        location = ev.location
        description = ev.description
        loaded = ev
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Add to a calendar", style = MaterialTheme.typography.titleMedium)
        val base = loaded
        if (base == null) {
            CircularProgressIndicator()
            return@Column
        }
        if (!base.hasStart) Text("No date found. Fill one in.", color = SecondaryText)
        OutlinedTextField(title, { title = it }, label = { Text("Title") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        Row(verticalAlignment = Alignment.CenterVertically) {
            Switch(checked = allDay, onCheckedChange = { on ->
                // Keep the picked days when switching between all-day and timed.
                CalendarEditFields.datePart(start)?.let { start = CalendarEditFields.fieldText(it, CalendarEditFields.timePart(start), on) }
                CalendarEditFields.datePart(end)?.let { end = CalendarEditFields.fieldText(it, CalendarEditFields.timePart(end), on) }
                allDay = on
            })
            Spacer(Modifier.width(8.dp))
            Text("All day")
        }
        CalendarDateTimeField("Starts", start, allDay, onChange = { start = it })
        CalendarDateTimeField("Ends (optional)", end, allDay, onChange = { end = it }, onClear = { end = "" })
        OutlinedTextField(location, { location = it }, label = { Text("Location") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(description, { description = it }, label = { Text("Notes") }, maxLines = 5, modifier = Modifier.fillMaxWidth())
        val edited = CalendarEditFields.apply(base, allDay, start, end, device)
            ?.copy(title = title.trim(), location = location.trim(), description = description.trim())
        if (edited == null && start.isNotBlank()) Text("The end has to be after the start.", color = SecondaryText)
        Text("Public: calendar events are posted to your relays.", color = SecondaryText, style = MaterialTheme.typography.bodySmall)
        ShareAccountSwitchRow(intent, needsSwitch, onSwitchAccount)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { edited?.let(onPublish) }, enabled = !busy && !needsSwitch && edited != null && title.isNotBlank()) {
                Text("Publish")
            }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }
    }
}
