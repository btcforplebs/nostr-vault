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
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.DEFAULT_SEARCH_RELAYS
import com.nostrvault.data.model.SearchRelayUrls
import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

@HiltViewModel
class SearchRelaySettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config

    /** False if [input] is not a usable relay URL. */
    fun addRelay(input: String): Boolean {
        val clean = SearchRelayUrls.normalize(input) ?: return false
        configStore.update { cfg ->
            val current = cfg.activeSearchRelays
            if (clean in current) cfg else cfg.copy(searchRelays = current + clean)
        }
        return true
    }

    fun removeRelay(url: String) = configStore.update { cfg ->
        cfg.copy(searchRelays = cfg.activeSearchRelays.filter { it != url })
    }

    /** Back to following the built-in list (null), not a frozen copy of it. */
    fun resetToDefaults() = configStore.update { it.copy(searchRelays = null) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchRelaySettingsScreen(
    onBack: () -> Unit,
    viewModel: SearchRelaySettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val colors = LocalNostrVaultColors.current
    val relays = config.activeSearchRelays
    val isDefault = config.searchRelays == null

    var newRelay by remember { mutableStateOf("") }
    var invalid by remember { mutableStateOf(false) }

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
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            SectionLabel("NIP-50 Search Relays")
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = newRelay,
                    onValueChange = { newRelay = it; invalid = false },
                    placeholder = { Text("wss://relay.example.com") },
                    singleLine = true,
                    isError = invalid,
                    modifier = Modifier.weight(1f),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = PrimaryText,
                        unfocusedTextColor = PrimaryText,
                        cursorColor = colors.primary,
                        focusedBorderColor = colors.primary,
                    ),
                )
                Spacer(Modifier.width(8.dp))
                Button(
                    onClick = {
                        if (viewModel.addRelay(newRelay)) newRelay = "" else invalid = true
                    },
                    enabled = newRelay.isNotBlank(),
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                ) { Text("Add") }
            }
            if (invalid) {
                Text(
                    "Not a relay URL (wss://…)",
                    color = ErrorRed, fontSize = 12.sp,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            Spacer(Modifier.height(8.dp))
            relays.forEach { relay ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                ) {
                    Text(relay, color = PrimaryText, fontSize = 13.sp, modifier = Modifier.weight(1f))
                    IconButton(onClick = { viewModel.removeRelay(relay) }) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Remove", tint = ErrorRed)
                    }
                }
            }
            if (relays.isEmpty()) {
                Text(
                    "No search relays. Global search will only look in your phone and Mac relay.",
                    color = SecondaryText, fontSize = 13.sp,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            }
            Text(
                "Global search asks these relays, your phone's relay and your Mac relay " +
                    "(if set) at the same time. Each relay gets separate profile and note " +
                    "searches, so a profiles-only relay still answers.",
                color = SecondaryText, fontSize = 12.sp,
                modifier = Modifier.padding(top = 6.dp),
            )

            Spacer(Modifier.height(20.dp))

            OutlinedButton(
                onClick = { viewModel.resetToDefaults() },
                enabled = !isDefault,
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Reset to Defaults", color = if (isDefault) SecondaryText else colors.primary) }
            Text(
                "Defaults: " + DEFAULT_SEARCH_RELAYS.joinToString(", ") { SearchRelayUrls.label(it) },
                color = SecondaryText, fontSize = 12.sp,
                modifier = Modifier.padding(top = 6.dp),
            )

            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        color = SecondaryText,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.sp,
        modifier = Modifier.padding(bottom = 8.dp),
    )
}
