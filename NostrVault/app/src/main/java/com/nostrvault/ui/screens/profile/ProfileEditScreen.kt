package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.text.style.TextOverflow
import com.nostrvault.ui.components.AvatarImage
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Profile editing screen for name, display_name, about, nip05, lud16, picture, website.
 */
@HiltViewModel
class ProfileEditViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) : ViewModel() {

    private val _displayName = MutableStateFlow("")
    val displayName = _displayName.asStateFlow()

    private val _name = MutableStateFlow("")
    val name = _name.asStateFlow()

    private val _about = MutableStateFlow("")
    val about = _about.asStateFlow()

    private val _pictureUrl = MutableStateFlow("")
    val pictureUrl = _pictureUrl.asStateFlow()

    private val _nip05 = MutableStateFlow("")
    val nip05 = _nip05.asStateFlow()

    private val _lud16 = MutableStateFlow("")
    val lud16 = _lud16.asStateFlow()

    private val _website = MutableStateFlow("")
    val website = _website.asStateFlow()

    /** Whose profile this is, for the preview's placeholder avatar. */
    val pubkey: String = configStore.activeAccountHexPubkey.value

    private val _isSaving = MutableStateFlow(false)
    val isSaving = _isSaving.asStateFlow()
    private val _saveError = MutableStateFlow<String?>(null)
    val saveError = _saveError.asStateFlow()

    init {
        val pubkey = configStore.activeAccountHexPubkey.value
        val profile = nostrService.profiles.value[pubkey]
        profile?.let {
            _displayName.value = it.displayName ?: ""
            _name.value = it.name ?: ""
            _about.value = it.about ?: ""
            _pictureUrl.value = it.pictureURL ?: ""
            _nip05.value = it.nip05 ?: ""
            _lud16.value = it.lud16 ?: ""
            _website.value = it.website ?: ""
        }
    }

    fun setDisplayName(v: String) { _displayName.value = v }
    fun setName(v: String) { _name.value = v }
    fun setAbout(v: String) { _about.value = v }
    fun setPictureUrl(v: String) { _pictureUrl.value = v }
    fun setNip05(v: String) { _nip05.value = v }
    fun setLud16(v: String) { _lud16.value = v }
    fun setWebsite(v: String) { _website.value = v }

    fun save(onSaved: () -> Unit) {
        viewModelScope.launch {
            _isSaving.value = true
            _saveError.value = null
            val metadataJson = buildJsonObject {
                if (_displayName.value.isNotBlank()) put("display_name", _displayName.value)
                if (_name.value.isNotBlank()) put("name", _name.value)
                if (_about.value.isNotBlank()) put("about", _about.value)
                if (_pictureUrl.value.isNotBlank()) put("picture", _pictureUrl.value)
                if (_nip05.value.isNotBlank()) put("nip05", _nip05.value)
                if (_lud16.value.isNotBlank()) put("lud16", _lud16.value)
                if (_website.value.isNotBlank()) put("website", _website.value)
            }.toString()
            // A bunker timeout or an Amber rejection throws; uncaught here it
            // crashed the app. Stay on the screen when nothing was published.
            val event = try {
                nostrService.signEventAsync(kind = 0, content = metadataJson, tags = emptyList())
            } catch (e: Exception) {
                _saveError.value = e.message ?: "Could not sign the profile"
                null
            }
            event?.let { nostrService.postEvent(it) }
            _isSaving.value = false
            if (event != null) {
                _saveError.value = null
                onSaved()
            } else if (_saveError.value == null) {
                _saveError.value = "Could not sign the profile"
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileEditScreen(
    onSaved: () -> Unit,
    onBack: () -> Unit,
    viewModel: ProfileEditViewModel = hiltViewModel(),
) {
    val displayName by viewModel.displayName.collectAsState()
    val name by viewModel.name.collectAsState()
    val about by viewModel.about.collectAsState()
    val pictureUrl by viewModel.pictureUrl.collectAsState()
    val nip05 by viewModel.nip05.collectAsState()
    val lud16 by viewModel.lud16.collectAsState()
    val website by viewModel.website.collectAsState()
    val isSaving by viewModel.isSaving.collectAsState()
    val saveError by viewModel.saveError.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Edit Profile") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                actions = {
                    TextButton(
                        onClick = { viewModel.save(onSaved) },
                        enabled = !isSaving,
                    ) {
                        if (isSaving) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                            )
                        } else {
                            Text("Save", color = colors.primary, fontWeight = FontWeight.SemiBold)
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
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(16.dp))
            saveError?.let {
                Text(
                    "Profile not saved: $it",
                    color = MaterialTheme.colorScheme.error,
                    fontSize = 14.sp,
                    modifier = Modifier.padding(bottom = 12.dp),
                )
            }
            ProfilePreview(
                pubkey = viewModel.pubkey,
                pictureUrl = pictureUrl,
                displayName = displayName,
                name = name,
                nip05 = nip05,
                about = about,
            )
            HorizontalDivider(color = SeparatorColor.copy(alpha = 0.5f), modifier = Modifier.padding(bottom = 16.dp))
            ProfileField("Display Name", displayName, viewModel::setDisplayName)
            ProfileField("Username", name, viewModel::setName)
            ProfileField("About", about, viewModel::setAbout, singleLine = false, minLines = 3)
            ProfileField("Profile Picture URL", pictureUrl, viewModel::setPictureUrl)
            ProfileField("NIP-05 Identifier", nip05, viewModel::setNip05)
            ProfileField("Lightning Address", lud16, viewModel::setLud16)
            ProfileField("Website", website, viewModel::setWebsite)
            Spacer(Modifier.height(32.dp))
        }
    }
}

/** How the profile will look, updating as the fields are edited. */
@Composable
private fun ProfilePreview(
    pubkey: String,
    pictureUrl: String,
    displayName: String,
    name: String,
    nip05: String,
    about: String,
) {
    val colors = LocalNostrVaultColors.current
    val shownName = displayName.ifBlank { name.ifBlank { "Unnamed" } }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp)
            .padding(bottom = 8.dp),
    ) {
        AvatarImage(
            url = pictureUrl.trim().ifEmpty { null },
            pubkey = pubkey,
            size = 56.dp,
            displayName = shownName,
            modifier = Modifier.border(1.5.dp, colors.primary.copy(alpha = 0.35f), CircleShape),
        )
        Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.weight(1f)) {
            Text(shownName, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (nip05.isNotBlank()) {
                Text(nip05, color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (about.isNotBlank()) {
                Text(about, color = PrimaryText.copy(alpha = 0.75f), fontSize = 12.sp,
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun ProfileField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    singleLine: Boolean = true,
    minLines: Int = 1,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = singleLine,
        minLines = minLines,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = LocalNostrVaultColors.current.primary,
            unfocusedBorderColor = SeparatorColor,
            cursorColor = LocalNostrVaultColors.current.primary,
            focusedLabelColor = LocalNostrVaultColors.current.primary,
        ),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 12.dp),
    )
}
