package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.PowPreferences
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject

/**
 * Proof of Work (NIP-13) settings screen.
 * Allows configuring mining difficulty per event type.
 */

@HiltViewModel
class PowSettingsViewModel @Inject constructor(
    val powPreferences: PowPreferences,
) : ViewModel()

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PowSettingsScreen(
    onBack: () -> Unit,
    viewModel: PowSettingsViewModel = hiltViewModel(),
) {
    val prefs = viewModel.powPreferences
    val noteEnabled by prefs.noteEnabled.collectAsState()
    val noteDifficulty by prefs.noteDifficulty.collectAsState()
    val reactionEnabled by prefs.reactionEnabled.collectAsState()
    val reactionDifficulty by prefs.reactionDifficulty.collectAsState()
    val dmEnabled by prefs.dmEnabled.collectAsState()
    val dmDifficulty by prefs.dmDifficulty.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Proof of Work") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
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
        ) {
            Text(
                text = "NIP-13 proof of work adds computational cost to your events, helping prevent spam and increasing relay acceptance.",
                color = SecondaryText,
                fontSize = 13.sp,
            )

            Spacer(Modifier.height(24.dp))

            PowSection(
                title = "Notes",
                subtitle = "Kind 1 text notes and reposts",
                help = SettingsHelp.ADV_POW,
                enabled = noteEnabled,
                difficulty = noteDifficulty,
                onToggle = prefs::setNoteEnabled,
                onDifficultyChange = prefs::setNoteDifficulty,
            )

            Spacer(Modifier.height(24.dp))

            PowSection(
                title = "Reactions",
                subtitle = "Kind 7 likes and emoji reactions",
                enabled = reactionEnabled,
                difficulty = reactionDifficulty,
                onToggle = prefs::setReactionEnabled,
                onDifficultyChange = prefs::setReactionDifficulty,
            )

            Spacer(Modifier.height(24.dp))

            PowSection(
                title = "Direct Messages",
                subtitle = "Kind 4 and NIP-17 encrypted messages",
                enabled = dmEnabled,
                difficulty = dmDifficulty,
                onToggle = prefs::setDmEnabled,
                onDifficultyChange = prefs::setDmDifficulty,
            )
        }
    }
}

@Composable
private fun PowSection(
    title: String,
    subtitle: String,
    enabled: Boolean,
    difficulty: Int,
    onToggle: (Boolean) -> Unit,
    onDifficultyChange: (Int) -> Unit,
    help: SettingsHelp? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = title,
                    color = PrimaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                if (help != null) InfoButton(help)
            }
            Text(
                text = subtitle,
                color = SecondaryText,
                fontSize = 13.sp,
            )
        }
        Switch(
            checked = enabled,
            onCheckedChange = onToggle,
            colors = SwitchDefaults.colors(
                checkedThumbColor = PrimaryText,
                checkedTrackColor = LocalNostrVaultColors.current.primary,
            ),
        )
    }

    if (enabled) {
        Spacer(Modifier.height(8.dp))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Easy", color = TertiaryText, fontSize = 12.sp)
            Slider(
                value = difficulty.toFloat(),
                onValueChange = { onDifficultyChange(it.toInt()) },
                valueRange = PowPreferences.MIN_DIFFICULTY.toFloat()..PowPreferences.MAX_DIFFICULTY.toFloat(),
                steps = (PowPreferences.MAX_DIFFICULTY - PowPreferences.MIN_DIFFICULTY) / 2 - 1,
                colors = SliderDefaults.colors(
                    thumbColor = LocalNostrVaultColors.current.primary,
                    activeTrackColor = LocalNostrVaultColors.current.primary,
                ),
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 8.dp),
            )
            Text("Hard", color = TertiaryText, fontSize = 12.sp)
        }
        Text(
            text = "Difficulty: $difficulty bits",
            color = SecondaryText,
            fontSize = 13.sp,
            modifier = Modifier.padding(start = 4.dp),
        )
    }
}
