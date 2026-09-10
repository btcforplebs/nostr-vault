package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
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
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class HavenRelaySettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
) : ViewModel() {

    private val _urlInput = MutableStateFlow("")
    val urlInput = _urlInput.asStateFlow()

    private val _saved = MutableStateFlow(false)
    val saved = _saved.asStateFlow()

    init {
        _urlInput.value = configStore.config.value.macRelayURL
    }

    fun setUrlInput(value: String) {
        _urlInput.value = value
        _saved.value = false
    }

    fun save() {
        viewModelScope.launch {
            configStore.update { it.copy(macRelayURL = _urlInput.value.trim()) }
            _saved.value = true
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HavenRelaySettingsScreen(
    onBack: () -> Unit,
    viewModel: HavenRelaySettingsViewModel = hiltViewModel(),
) {
    val urlInput by viewModel.urlInput.collectAsState()
    val saved by viewModel.saved.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Haven Relay") },
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
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(16.dp))

            Text(
                text = "SYNC RELAY",
                color = SecondaryText,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.sp,
                modifier = Modifier.padding(bottom = 8.dp),
            )

            OutlinedTextField(
                value = urlInput,
                onValueChange = viewModel::setUrlInput,
                placeholder = { Text("wss://relay.yourdomain.com") },
                label = { Text("Haven Relay URL") },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.primary,
                    unfocusedBorderColor = SeparatorColor,
                    focusedLabelColor = colors.primary,
                    cursorColor = colors.primary,
                ),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(8.dp))

            Text(
                text = "Your Mac, Linux, or cloud-hosted Haven relay. When set, the app syncs your notes from this relay so posts made on other devices appear here.",
                color = SecondaryText,
                fontSize = 13.sp,
                lineHeight = 18.sp,
            )

            Spacer(Modifier.height(20.dp))

            Button(
                onClick = viewModel::save,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                shape = RoundedCornerShape(10.dp),
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
            ) {
                Text("Save", color = PrimaryText, fontWeight = FontWeight.SemiBold)
            }

            if (saved) {
                Spacer(Modifier.height(12.dp))
                Surface(
                    color = SuccessGreen.copy(alpha = 0.1f),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                    ) {
                        Icon(
                            NostrVaultIcons.Check,
                            contentDescription = null,
                            tint = SuccessGreen,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text("Saved", color = SuccessGreen, fontSize = 14.sp)
                    }
                }
            }
        }
    }
}
