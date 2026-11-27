package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.MutedWordRow
import com.nostrvault.service.MutedWords
import com.nostrvault.service.NostrService
import com.nostrvault.service.heldMuteList
import com.nostrvault.service.mutedWordRows
import com.nostrvault.service.publishMutedWordChange
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * Settings › Muted words: the words and phrases the active account's kind
 * 10000 mutes (NIP-51 `word`). Notes, replies and notifications holding one
 * are hidden (MuteRules). New words are private by default (Logen
 * 2026-11-27): encrypted in the list, so nobody else sees what you muted.
 * iOS: MutedWordsSettingsView; web: screens/settings/MutedWords.jsx.
 */
@HiltViewModel
class MutedWordsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val notificationManager: NotificationManager,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config

    private val _busy = MutableStateFlow(false)
    /** A change is being published: one at a time, so two never race on the newest list. */
    val busy: StateFlow<Boolean> = _busy.asStateFlow()

    fun rows(cfg: HavenConfig): List<MutedWordRow> {
        val npub = cfg.activeOrOwnerNpub()
        return mutedWordRows(cfg.mutedPerAccount[npub], cfg.privateMutedPerAccount[npub])
    }

    /**
     * The account's list has a private part this device hasn't opened (a
     * signer that isn't connected, a read-only account): its private words
     * aren't shown, and adding one is refused when it is published.
     */
    fun privateUnknown(cfg: HavenConfig): Boolean {
        val npub = cfg.activeOrOwnerNpub()
        if (npub in cfg.privateMutedPerAccount) return false
        val hex = nostrService.npubToHex(npub) ?: return false
        return heldMuteList(hex)?.content?.isNotBlank() == true
    }

    fun add(input: String, privately: Boolean) = change(add = input, privately = privately)

    fun remove(word: String) = change(remove = word)

    private fun change(add: String? = null, remove: String? = null, privately: Boolean = true) {
        if (_busy.value) return
        _busy.value = true
        // Nothing is kept on this device first, so leaving the screen
        // mid-publish must not cancel it.
        viewModelScope.launch {
            withContext(NonCancellable) {
                try {
                    val npub = configStore.config.value.activeOrOwnerNpub()
                    nostrService.publishMutedWordChange(npub, add, remove, privately)
                        ?.let { notificationManager.showError(it) }
                } finally {
                    _busy.value = false
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MutedWordsScreen(
    onBack: () -> Unit,
    viewModel: MutedWordsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val busy by viewModel.busy.collectAsState()
    val colors = LocalNostrVaultColors.current
    val rows = viewModel.rows(config)
    val privateUnknown = viewModel.privateUnknown(config)

    var input by remember { mutableStateOf("") }
    var privately by remember { mutableStateOf(true) }
    val word = MutedWords.normalize(input)
    val canAdd = word != null && !busy && rows.none { it.word == word }
    val submit = {
        if (canAdd) {
            viewModel.add(input, privately)
            input = ""
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Muted words") },
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
            SectionLabel("Mute a word")
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it.take(MutedWords.MAX_LENGTH) },
                    placeholder = { Text("A word or phrase") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { submit() }),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = PrimaryText,
                        unfocusedTextColor = PrimaryText,
                        cursorColor = colors.primary,
                        focusedBorderColor = colors.primary,
                    ),
                )
                Spacer(Modifier.width(8.dp))
                Button(
                    onClick = submit,
                    enabled = canAdd,
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                ) { Text("Mute") }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            ) {
                Text("Public", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
                Switch(
                    checked = !privately,
                    onCheckedChange = { privately = !it },
                    colors = SwitchDefaults.colors(checkedTrackColor = colors.primary),
                )
            }
            Caption(
                if (privately) {
                    "Only you will see this word. It is encrypted in your mute list. Notes, replies and " +
                        "notifications with it are hidden once your relays have it."
                } else {
                    "Anyone can see this word in your mute list. Notes, replies and notifications with it are hidden."
                },
            )
            if (privateUnknown) {
                Text(
                    "Your private muted words couldn't be opened on this device, so they aren't shown. " +
                        "Is your signer connected? Private words can't be added until it is.",
                    color = ErrorRed,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }

            Spacer(Modifier.height(24.dp))
            SectionLabel("Muted")
            if (rows.isEmpty()) {
                Text("No muted words.", color = TertiaryText, fontSize = 14.sp, modifier = Modifier.padding(vertical = 4.dp))
            } else {
                rows.forEach { row -> MutedWordLine(row, enabled = !busy) { viewModel.remove(row.word) } }
            }
            Caption("Whole words only, in any case: muting \"cat\" hides \"Cat!\" but not \"category\". Your own notes are never hidden.")
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun MutedWordLine(row: MutedWordRow, enabled: Boolean, onRemove: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
    ) {
        Text(row.word, color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Text(
            if (row.private) "Private" else "Public",
            color = SecondaryText,
            fontSize = 12.sp,
            modifier = Modifier.padding(horizontal = 8.dp),
        )
        TextButton(onClick = onRemove, enabled = enabled) { Text("Unmute", color = ErrorRed) }
    }
}
