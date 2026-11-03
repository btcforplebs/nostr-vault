package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.service.shareportal.CalendarEditFields
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset

/**
 * A calendar card's start or end: a date button (Material date picker) and,
 * for a timed event, a time button (time picker). The value stays the text
 * [CalendarEditFields] reads, so the card's publish path is unchanged.
 * [onClear] is offered for an optional end.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CalendarDateTimeField(
    label: String,
    text: String,
    allDay: Boolean,
    onChange: (String) -> Unit,
    onClear: (() -> Unit)? = null,
) {
    var pickingDate by remember { mutableStateOf(false) }
    var pickingTime by remember { mutableStateOf(false) }
    val date = CalendarEditFields.datePart(text)
    val time = CalendarEditFields.timePart(text)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = { pickingDate = true }) { Text(date?.toString() ?: "Pick a date") }
            if (!allDay) {
                OutlinedButton(onClick = { pickingTime = true }, enabled = date != null) {
                    Text(time?.let { "%02d:%02d".format(it.hour, it.minute) } ?: "Pick a time")
                }
            }
            if (onClear != null && text.isNotBlank()) TextButton(onClick = onClear) { Text("Clear") }
        }
    }
    if (pickingDate) {
        // The picker works in UTC millis at midnight; convert at the edge only.
        val state = rememberDatePickerState(
            initialSelectedDateMillis = (date ?: LocalDate.now()).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
        )
        DatePickerDialog(
            onDismissRequest = { pickingDate = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { millis ->
                        val picked = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate()
                        onChange(CalendarEditFields.fieldText(picked, time, allDay))
                    }
                    pickingDate = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { pickingDate = false }) { Text("Cancel") } },
        ) { DatePicker(state = state) }
    }
    if (pickingTime && date != null) {
        val start = time ?: LocalTime.of(9, 0)
        val state = rememberTimePickerState(initialHour = start.hour, initialMinute = start.minute, is24Hour = true)
        AlertDialog(
            onDismissRequest = { pickingTime = false },
            confirmButton = {
                TextButton(onClick = {
                    onChange(CalendarEditFields.fieldText(date, LocalTime.of(state.hour, state.minute), allDay = false))
                    pickingTime = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { pickingTime = false }) { Text("Cancel") } },
            text = { TimePicker(state = state) },
        )
    }
}
