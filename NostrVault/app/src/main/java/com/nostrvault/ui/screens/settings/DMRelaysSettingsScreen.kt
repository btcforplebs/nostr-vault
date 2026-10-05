package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * DM relay editor. Every change republishes the DM inbox list (kind 10050)
 * after a 2 second pause, as iOS DMSettingsView does.
 */
@HiltViewModel
class DMRelaysSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) : ViewModel() {

    private val _relays = MutableStateFlow(configStore.config.value.dmRelays)
    val relays = _relays.asStateFlow()

    private val _newRelayUrl = MutableStateFlow("")
    val newRelayUrl = _newRelayUrl.asStateFlow()

    /** The owner's Haven inbox, which the published list leads with. */
    val havenInbox: String get() = configStore.config.value.ownHavenDMInboxURL

    private val _showPublished = MutableStateFlow(false)
    val showPublished = _showPublished.asStateFlow()

    private var publishJob: Job? = null
    private var publishPending = false

    fun setNewRelayUrl(url: String) { _newRelayUrl.value = url }

    fun addRelay() {
        val url = _newRelayUrl.value.trim().let {
            if (!it.startsWith("wss://") && !it.startsWith("ws://")) "wss://$it" else it
        }
        if (url == "wss://") return
        if (url in _relays.value) return
        _relays.value = _relays.value + url
        _newRelayUrl.value = ""
        save()
    }

    fun removeRelay(url: String) {
        _relays.value = _relays.value - url
        save()
    }

    private fun save() {
        configStore.update { it.copy(dmRelays = _relays.value) }
        publishPending = true
        publishJob?.cancel()
        publishJob = viewModelScope.launch {
            delay(2_000)
            publish()
        }
    }

    private fun publish() {
        if (!publishPending) return
        publishPending = false
        // Publishes the Haven inbox first, then the relays above, and stamps
        // it as the newest change so other devices adopt it.
        nostrService.publishOwnerDMInboxList()
        _showPublished.value = true
        viewModelScope.launch {
            delay(3_000)
            _showPublished.value = false
        }
    }

    override fun onCleared() {
        // Leaving inside the debounce still publishes the edit.
        publishJob?.cancel()
        if (publishPending) {
            publishPending = false
            nostrService.publishOwnerDMInboxList()
        }
        super.onCleared()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DMRelaysSettingsScreen(
    onBack: () -> Unit,
    viewModel: DMRelaysSettingsViewModel = hiltViewModel(),
) {
    val relays by viewModel.relays.collectAsState()
    val newRelayUrl by viewModel.newRelayUrl.collectAsState()
    val showPublished by viewModel.showPublished.collectAsState()
    val colors = LocalNostrVaultColors.current
    val havenInbox = viewModel.havenInbox

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("DM Relays") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                actions = { InfoButton(SettingsHelp.SHARE_DM_RELAYS) },
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
                .padding(padding),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                OutlinedTextField(
                    value = newRelayUrl,
                    onValueChange = viewModel::setNewRelayUrl,
                    placeholder = { Text("wss://relay.example.com") },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.primary,
                        unfocusedBorderColor = SeparatorColor,
                        cursorColor = colors.primary,
                    ),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                IconButton(
                    onClick = viewModel::addRelay,
                    enabled = newRelayUrl.isNotBlank(),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Create,
                        contentDescription = "Add",
                        tint = if (newRelayUrl.isNotBlank()) colors.primary else TertiaryText,
                    )
                }
            }

            if (havenInbox.isNotEmpty()) {
                Text(
                    text = "$havenInbox comes first. People send your DMs to it, your own sent messages go there too, and all your devices read from it. It stays first while it's set as your relay address.",
                    color = SecondaryText,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }

            if (showPublished) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Icon(
                        NostrVaultIcons.Check,
                        contentDescription = null,
                        tint = SuccessGreen,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text("DM relay preferences published to network", color = SuccessGreen, fontSize = 13.sp)
                }
            }

            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

            if (relays.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(32.dp),
                ) {
                    Text("No DM relays configured", color = SecondaryText, fontSize = 15.sp)
                }
            } else {
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(relays) { relay ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Domain,
                                contentDescription = null,
                                tint = colors.primary,
                                modifier = Modifier.size(20.dp),
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                text = relay.removePrefix("wss://"),
                                color = PrimaryText,
                                fontSize = 15.sp,
                                modifier = Modifier.weight(1f),
                            )
                            IconButton(onClick = { viewModel.removeRelay(relay) }) {
                                Icon(
                                    imageVector = NostrVaultIcons.Delete,
                                    contentDescription = "Remove",
                                    tint = ErrorRed,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }
                        HorizontalDivider(
                            color = SeparatorColor,
                            thickness = 0.5.dp,
                            modifier = Modifier.padding(start = 16.dp),
                        )
                    }
                }
            }
        }
    }
}
