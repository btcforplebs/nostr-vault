package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.setup.RelayCheck
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen

// ══════════════════════════════════════════════════════════════════
// Relay check
// ══════════════════════════════════════════════════════════════════

/**
 * Between Your key and the import tour: checks which relays answer and have
 * this person's notes, so the import can't hang on a dead one. "Start
 * import" saves the picks to `importSeedRelays`, which is what the import reads.
 */
@Composable
internal fun RelayCheckStep(viewModel: SetupWizardViewModel) {
    val rows by viewModel.relayRows.collectAsState()
    val isChecking by viewModel.isCheckingRelays.collectAsState()
    val error by viewModel.error.collectAsState()
    var editing by rememberSaveable { mutableStateOf(false) }
    var newRelay by rememberSaveable { mutableStateOf("") }
    val onCount = rows.count { it.isOn }

    LaunchedEffect(Unit) { viewModel.startRelayCheck() }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            if (isChecking) "Checking your relays" else "Ready to import",
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            if (isChecking) "Looking for your notes. This takes a few seconds." else RelayCheck.summary(rows),
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(16.dp))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(WizardBgCard)
                .border(1.dp, WizardBorderSubtle, RoundedCornerShape(12.dp)),
        ) {
            rows.forEachIndexed { i, row ->
                RelayCheckRow(row, editing, onToggle = { viewModel.setRelayRowOn(row.url, it) })
                if (i < rows.lastIndex) HorizontalDivider(color = WizardBorderSubtle)
            }
        }

        if (editing) {
            Spacer(Modifier.height(12.dp))
            val add = { if (viewModel.addRelayCheckRow(newRelay)) newRelay = "" }
            OutlinedTextField(
                value = newRelay,
                onValueChange = { newRelay = it },
                placeholder = { Text("Add a relay, e.g. relay.example.com") },
                singleLine = true,
                trailingIcon = {
                    TextButton(onClick = add, enabled = RelayCheck.normalize(newRelay) != null) {
                        Text("Add", color = WizardAccent, fontWeight = FontWeight.SemiBold)
                    }
                },
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { add() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        if (!isChecking && onCount == 0) {
            TextButton(onClick = { viewModel.startRelayCheck(force = true) }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text("Check again", color = WizardAccent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = ErrorRed, fontSize = 13.sp, textAlign = TextAlign.Center)
        }

        Spacer(Modifier.height(20.dp))
        WizardPrimaryButton(
            text = "Start import",
            enabled = !isChecking && onCount > 0,
            onClick = viewModel::startImportFromRelayCheck,
        )
        TextButton(
            onClick = { editing = !editing },
            enabled = !isChecking,
            modifier = Modifier.heightIn(min = 48.dp),
        ) {
            Text(if (editing) "Done" else "Change import relays", color = WizardAccent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun RelayCheckRow(row: RelayCheck.Row, editing: Boolean, onToggle: (Boolean) -> Unit) {
    val dot = when (row.result) {
        RelayCheck.Result.Checking -> Muted
        is RelayCheck.Result.Ready -> SuccessGreen
        is RelayCheck.Result.Slow -> WizardAccent
        else -> ErrorRed
    }
    val name = row.url.removePrefix("wss://")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .then(
                if (editing) Modifier
                else Modifier.semantics(mergeDescendants = true) {},
            ),
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    name,
                    color = PrimaryText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (row.isYours) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "yours",
                        color = WizardAccent,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .background(WizardAccent.copy(alpha = 0.15f))
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }
            Spacer(Modifier.height(2.dp))
            Text(row.result.label, color = SecondaryText, fontSize = 12.sp)
        }
        if (editing) {
            Switch(
                checked = row.isOn,
                onCheckedChange = onToggle,
                enabled = row.result.canImport,
                colors = SwitchDefaults.colors(checkedTrackColor = WizardAccent),
                modifier = Modifier.semantics { contentDescription = "Import from $name" },
            )
        }
    }
}
