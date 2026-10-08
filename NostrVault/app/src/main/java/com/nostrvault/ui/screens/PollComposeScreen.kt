package com.nostrvault.ui.screens

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.NIP88Poll
import com.nostrvault.data.model.PollDraft
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground
import java.text.DateFormat
import java.util.Calendar
import java.util.Date

/** When voting closes, counted from the moment Post is tapped. Twin of iOS PollComposeView.Closing. */
internal enum class PollClosing(val label: String, val seconds: Long?) {
    ONE_HOUR("1 hour", 3600),
    ONE_DAY("1 day", 24 * 3600),
    THREE_DAYS("3 days", 3 * 24 * 3600),
    ONE_WEEK("1 week", 7 * 24 * 3600),
    NEVER("Never", null),
    CUSTOM("Pick a time", null);

    /** Unix seconds voting ends, or null for never. */
    fun endsAt(nowSecs: Long, customSecs: Long): Long? = when (this) {
        NEVER -> null
        CUSTOM -> customSecs
        else -> seconds?.let { nowSecs + it }
    }
}

/**
 * Posts a NIP-88 poll (kind 1068): a question, two to ten options, single or
 * multiple choice, and when voting closes. Port of iOS PollComposeView.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PollComposeScreen(onDone: () -> Unit, viewModel: ModeComposeViewModel) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val busy by viewModel.busy.collectAsState()
    val error by viewModel.error.collectAsState()

    var question by rememberSaveable { mutableStateOf("") }
    var options by rememberSaveable(
        stateSaver = listSaver<List<String>, String>({ it }, { it }),
    ) { mutableStateOf(listOf("", "")) }
    var multiple by rememberSaveable { mutableStateOf(false) }
    var closing by rememberSaveable { mutableStateOf(PollClosing.ONE_DAY) }
    var customEnd by rememberSaveable { mutableStateOf(System.currentTimeMillis() / 1000 + 24 * 3600) }
    var closingMenu by remember { mutableStateOf(false) }

    val nowSecs = System.currentTimeMillis() / 1000
    val draft = PollDraft(
        question = question,
        options = options,
        type = if (multiple) NIP88Poll.PollType.MULTIPLE else NIP88Poll.PollType.SINGLE,
        endsAt = closing.endsAt(nowSecs, customEnd),
    )
    // Why Post is off, when the reason is not plain from the form.
    val hint = when {
        draft.hasDuplicateOptions -> "Two options are the same."
        closing == PollClosing.CUSTOM && customEnd <= nowSecs -> "Pick a closing time that's still ahead."
        else -> null
    }

    fun pickCustomEnd() {
        val cal = Calendar.getInstance().apply { timeInMillis = customEnd * 1000 }
        DatePickerDialog(context, { _, y, m, d ->
            TimePickerDialog(context, { _, h, min ->
                cal.set(y, m, d, h, min, 0)
                customEnd = cal.timeInMillis / 1000
            }, cal.get(Calendar.HOUR_OF_DAY), cal.get(Calendar.MINUTE), android.text.format.DateFormat.is24HourFormat(context)).show()
        }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)).apply {
            datePicker.minDate = System.currentTimeMillis()
        }.show()
    }

    BackHandler(enabled = busy) {}

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New poll") },
                navigationIcon = {
                    IconButton(onClick = onDone, enabled = !busy) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Cancel")
                    }
                },
                actions = {
                    Button(
                        onClick = {
                            // The end time is counted from the tap, not from when the screen opened.
                            val now = System.currentTimeMillis() / 1000
                            viewModel.publishPoll(draft.copy(endsAt = closing.endsAt(now, customEnd)), onDone)
                        },
                        enabled = draft.isComplete(nowSecs) && !busy,
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                        shape = RoundedCornerShape(20.dp),
                        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
                    ) {
                        if (busy) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = PrimaryText)
                        } else {
                            Text("Post", fontWeight = FontWeight.SemiBold, color = PrimaryText)
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = question,
                onValueChange = { question = it },
                label = { Text("Ask a question") },
                enabled = !busy,
                maxLines = 4,
                modifier = Modifier.fillMaxWidth(),
            )

            Text("Options", color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            options.forEachIndexed { index, value ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = value,
                        onValueChange = { text -> options = options.toMutableList().also { it[index] = text } },
                        label = { Text("Option ${index + 1}") },
                        singleLine = true,
                        enabled = !busy,
                        modifier = Modifier.weight(1f),
                    )
                    if (options.size > PollDraft.MIN_OPTIONS) {
                        IconButton(
                            onClick = { options = options.toMutableList().also { it.removeAt(index) } },
                            enabled = !busy,
                        ) {
                            Icon(NostrVaultIcons.Dismiss, contentDescription = "Remove option ${index + 1}", tint = Color(0xFFFF453A))
                        }
                    }
                }
            }
            if (options.size < PollDraft.MAX_OPTIONS) {
                TextButton(onClick = { options = options + "" }, enabled = !busy) {
                    Icon(NostrVaultIcons.Create, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Add option")
                }
            }
            Text("At least two, up to ${PollDraft.MAX_OPTIONS}.", color = SecondaryText, fontSize = 12.sp)

            Text("Voters can pick", color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(selected = !multiple, onClick = { multiple = false }, label = { Text("One") }, enabled = !busy)
                FilterChip(selected = multiple, onClick = { multiple = true }, label = { Text("Any") }, enabled = !busy)
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Voting closes", color = SecondaryText, fontSize = 14.sp, modifier = Modifier.weight(1f))
                androidx.compose.foundation.layout.Box {
                    TextButton(onClick = { closingMenu = true }, enabled = !busy) { Text(closing.label) }
                    DropdownMenu(expanded = closingMenu, onDismissRequest = { closingMenu = false }) {
                        PollClosing.entries.forEach { option ->
                            DropdownMenuItem(
                                text = { Text(option.label) },
                                onClick = {
                                    closingMenu = false
                                    closing = option
                                    if (option == PollClosing.CUSTOM) pickCustomEnd()
                                },
                            )
                        }
                    }
                }
            }
            if (closing == PollClosing.CUSTOM) {
                TextButton(onClick = { pickCustomEnd() }, enabled = !busy) {
                    Text("Closes " + DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(customEnd * 1000)))
                }
            }
            Text(
                "Results show to everyone who has voted, and to all once voting closes.",
                color = SecondaryText,
                fontSize = 12.sp,
            )

            (error ?: hint)?.let {
                Text(it, color = if (error != null) Color(0xFFFF453A) else SecondaryText, fontSize = 13.sp)
            }
        }
    }
}
