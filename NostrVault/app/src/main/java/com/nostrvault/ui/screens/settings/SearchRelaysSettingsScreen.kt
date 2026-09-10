package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.NIP50_SEARCH_RELAYS
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Editor for the NIP-50 search relays used by Network-scope search.
 * Mirrors [RelayListEditorScreen]; an empty custom list falls back to the
 * built-in defaults ([NIP50_SEARCH_RELAYS] via HavenConfig.activeSearchRelays).
 */

@HiltViewModel
class SearchRelaysSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
) : ViewModel() {

    private val _relays = MutableStateFlow<List<String>>(emptyList())
    val relays = _relays.asStateFlow()

    private val _newRelayUrl = MutableStateFlow("")
    val newRelayUrl = _newRelayUrl.asStateFlow()

    val defaults: List<String> = NIP50_SEARCH_RELAYS

    init {
        _relays.value = configStore.config.value.searchRelays
    }

    fun setNewRelayUrl(url: String) { _newRelayUrl.value = url }

    fun addRelay() {
        val url = _newRelayUrl.value.trim()
        if (url.isBlank() || !url.startsWith("wss://")) return
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
        viewModelScope.launch {
            configStore.update { it.copy(searchRelays = _relays.value) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchRelaysSettingsScreen(
    onBack: () -> Unit,
    viewModel: SearchRelaysSettingsViewModel = hiltViewModel(),
) {
    val relays by viewModel.relays.collectAsState()
    val newRelayUrl by viewModel.newRelayUrl.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Search Relays") },
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
                .padding(padding),
        ) {
            Text(
                text = "NIP-50 relays used for Network search. Leave empty to use the built-in defaults.",
                color = SecondaryText,
                fontSize = 13.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            )

            // Add relay input
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
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

            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

            if (relays.isEmpty()) {
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    item {
                        Text(
                            text = "Using default search relays",
                            color = SecondaryText,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                        )
                    }
                    items(viewModel.defaults) { relay ->
                        SearchRelayRow(url = relay, onRemove = null)
                        HorizontalDivider(
                            color = SeparatorColor,
                            thickness = 0.5.dp,
                            modifier = Modifier.padding(start = 16.dp),
                        )
                    }
                }
            } else {
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(relays) { relay ->
                        SearchRelayRow(
                            url = relay,
                            onRemove = { viewModel.removeRelay(relay) },
                        )
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

@Composable
private fun SearchRelayRow(
    url: String,
    onRemove: (() -> Unit)?,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Domain,
            contentDescription = null,
            tint = if (onRemove != null) LocalNostrVaultColors.current.primary else TertiaryText,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = url.removePrefix("wss://"),
            color = if (onRemove != null) PrimaryText else SecondaryText,
            fontSize = 15.sp,
            modifier = Modifier.weight(1f),
        )
        if (onRemove != null) {
            IconButton(onClick = onRemove) {
                Icon(
                    imageVector = NostrVaultIcons.Delete,
                    contentDescription = "Remove",
                    tint = ErrorRed,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}
