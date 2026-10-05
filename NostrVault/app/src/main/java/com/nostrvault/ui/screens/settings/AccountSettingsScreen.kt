package com.nostrvault.ui.screens.settings

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.NIP46Service
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrConnectPairing
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class AccountSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val credentialStore: CredentialStore,
    private val nostrService: NostrService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val nip46Connected: StateFlow<Boolean> = NIP46Service.isConnected

    fun hexFor(npub: String): String = HavenBridge.decodeNpub(npub) ?: ""
    fun profileFor(npub: String): FeedProfile? = profiles.value[hexFor(npub)]

    fun ensureProfiles(npubs: List<String>) {
        val hexes = npubs.mapNotNull { HavenBridge.decodeNpub(it) }
        if (hexes.isNotEmpty()) nostrService.fetchMissingProfiles(hexes)
    }

    fun hasLocalKey(npub: String, cfg: HavenConfig): Boolean {
        if (npub == cfg.ownerNpub) {
            return cfg.ownerHexKey != null || cfg.ownerNcryptsec != null ||
                (hexFor(npub).isNotEmpty() && credentialStore.getNsec(hexFor(npub)) != null)
        }
        return credentialStore.getCredentialHexKey(npub) != null ||
            (hexFor(npub).isNotEmpty() && credentialStore.getNsec(hexFor(npub)) != null)
    }

    fun switchTo(npub: String) = viewModelScope.launch { configStore.switchActiveAccount(npub) }

    /** Add a view-only account from an npub (no signing key). */
    fun addViewOnly(npub: String) {
        val clean = npub.trim()
        if (!clean.startsWith("npub1")) return
        configStore.addAccount(clean)
        configStore.setSigningMode(clean, "local")
        ensureProfiles(listOf(clean))
    }

    /** Import a signing account from an nsec. Returns the resulting npub or null. */
    fun importKey(nsec: String): String? {
        val hex = HavenBridge.decodeNsec(nsec.trim()) ?: return null
        val pub = HavenBridge.getPublicKey(hex) ?: return null
        val npub = HavenBridge.encodeNpub(pub) ?: return null
        credentialStore.storeCredentialHexKey(hex, npub)
        credentialStore.saveNsec(hex, pub)
        configStore.addAccount(npub)
        configStore.setSigningMode(npub, "local")
        ensureProfiles(listOf(npub))
        return npub
    }

    /** Connect a NIP-46 remote signer. Returns the account npub or null. */
    fun connectSigner(bunkerUri: String, onResult: (String?) -> Unit) {
        viewModelScope.launch {
            val keypair = HavenBridge.generateKeyPair()
            val parts = keypair?.split(":")
            if (parts == null || parts.size != 2) { onResult(null); return@launch }
            onResult(addSignerAccount(bunkerUri.trim(), parts[0], parts[1]))
        }
    }

    /**
     * Finishes a nostrconnect:// pairing: stored like a pasted bunker link
     * (secret-less, with the pairing's own client key), then connected.
     * Returns the account npub or null. Runs in the view model's scope so
     * leaving the screen mid-connect doesn't cut the save in half.
     */
    suspend fun pairNostrConnect(request: NIP46Service.NostrConnectRequest, signerPubkey: String): String? =
        viewModelScope.async {
            addSignerAccount(
                NIP46Service.bunkerUri(signerPubkey, request.relays),
                request.clientSecretKey,
                request.clientPubkey,
            )
        }.await()

    private suspend fun addSignerAccount(uri: String, clientSec: String, clientPub: String): String? {
        val signerPubkey = NIP46Service.connect(clientSec, uri) ?: return null
        val npub = HavenBridge.encodeNpub(signerPubkey) ?: return null
        configStore.setBunkerConfig(
            npub,
            AccountBunkerConfig(
                bunkerURI = uri,
                signerPubkey = signerPubkey,
                clientSecretKey = clientSec,
                clientPubkey = clientPub,
            ),
        )
        configStore.addAccount(npub)
        configStore.setSigningMode(npub, "nip46")
        ensureProfiles(listOf(npub))
        return npub
    }

    /** Bumped when a key is removed: [hasLocalKey] reads the credential store, not config. */
    private val _keysChanged = kotlinx.coroutines.flow.MutableStateFlow(0)
    val keysChanged: StateFlow<Int> = _keysChanged

    /**
     * Deletes the private key stored on this device for [npub], as iOS
     * "Remove Local Key" does. With a remote signer, signing falls back to it;
     * without one nothing here can sign for the account (browse-only).
     */
    fun removeLocalKey(npub: String) {
        val cfg = config.value
        val hex = hexFor(npub)
        if (npub == cfg.ownerNpub) {
            configStore.update { it.copy(ownerHexKey = null, ownerNcryptsec = null) }
            credentialStore.deleteKeychainPassword(npub)
        } else {
            credentialStore.deleteCredentialHexKey(npub)
        }
        if (hex.isNotEmpty()) credentialStore.deleteNsec(hex)
        if (cfg.signingMode(npub) == "local" && cfg.bunkerConfig(npub) != null) {
            configStore.setSigningMode(npub, "nip46")
        }
        _keysChanged.value++
    }

    fun disconnectSigner(npub: String) {
        // Closes this account's signer session (and detaches it if active),
        // not whichever account's session happens to be active.
        configStore.removeBunkerConfig(npub)
        configStore.setSigningMode(npub, "local")
    }

    fun setSigningMode(npub: String, mode: String) = configStore.setSigningMode(npub, mode)

    fun removeAccount(npub: String) = configStore.removeAccount(npub)

    fun togglePublishRelayList(npub: String, enabled: Boolean) {
        configStore.setPublishRelayList(npub, enabled)
        if (enabled) nostrService.publishRelayList(npub)
    }

    /** Resolve the nsec for an account (call only after biometric auth). */
    fun revealNsec(npub: String): String? {
        val cfg = config.value
        val hexKey = if (npub == cfg.ownerNpub) {
            cfg.ownerHexKey
                ?: cfg.ownerNcryptsec?.let { nc ->
                    val pw = credentialStore.getKeychainPassword(npub) ?: return@let null
                    com.nostrvault.service.NIP49Service.decrypt(nc, pw)
                }
                ?: hexFor(npub).takeIf { it.isNotEmpty() }?.let { credentialStore.getNsec(it) }
        } else {
            credentialStore.getCredentialHexKey(npub)
                ?: hexFor(npub).takeIf { it.isNotEmpty() }?.let { credentialStore.getNsec(it) }
        } ?: return null
        return HavenBridge.encodeNsec(hexKey)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountSettingsScreen(
    onBack: () -> Unit,
    viewModel: AccountSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val nip46Connected by viewModel.nip46Connected.collectAsState()
    val keysChanged by viewModel.keysChanged.collectAsState()
    val colors = LocalNostrVaultColors.current

    val accounts = config.allAccountNpubs()
    val activeNpub = config.activeOrOwnerNpub()
    var selected by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(accounts) { viewModel.ensureProfiles(accounts) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Accounts") },
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
            accounts.forEach { npub ->
                val isOwner = npub == config.ownerNpub
                val isActive = npub == activeNpub
                AccountRow(
                    npub = npub,
                    hex = viewModel.hexFor(npub),
                    displayName = viewModel.profileFor(npub)?.bestName
                        ?: if (isOwner) "Owner" else npub.take(12) + "...",
                    pictureURL = viewModel.profileFor(npub)?.pictureURL,
                    mode = config.signingMode(npub),
                    hasBunker = config.bunkerConfig(npub) != null,
                    isOwner = isOwner,
                    isActive = isActive,
                    connected = isActive && nip46Connected,
                    expanded = selected == npub,
                    onClick = { selected = if (selected == npub) null else npub },
                )
                if (selected == npub) {
                    AccountDetail(
                        npub = npub,
                        cfg = config,
                        isOwner = isOwner,
                        isActive = isActive,
                        hasLocalKey = remember(config, keysChanged) { viewModel.hasLocalKey(npub, config) },
                        viewModel = viewModel,
                    )
                }
                HorizontalDivider(color = TertiaryGroupedBg)
            }

            Spacer(Modifier.height(20.dp))
            AddAccountSection(viewModel)

            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun AccountRow(
    npub: String,
    hex: String,
    displayName: String,
    pictureURL: String?,
    mode: String,
    hasBunker: Boolean,
    isOwner: Boolean,
    isActive: Boolean,
    connected: Boolean,
    expanded: Boolean,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
    ) {
        AvatarImage(url = pictureURL, pubkey = hex, size = 40.dp, displayName = displayName)
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(displayName, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                if (isOwner) {
                    Spacer(Modifier.width(6.dp))
                    Badge2("Owner", colorPrimaryFor(mode = "owner"))
                }
            }
            val modeLabel = when {
                hasBunker || mode == "nip46" -> "Remote Signer"
                mode == "amber" -> "Amber"
                else -> "Local Key"
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(modeLabel, color = SecondaryText, fontSize = 12.sp)
                if ((hasBunker || mode == "nip46") && isActive) {
                    Spacer(Modifier.width(6.dp))
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(if (connected) Color(0xFF4CAF50) else ErrorRed),
                    )
                }
            }
        }
        if (isActive) {
            Icon(NostrVaultIcons.Check, contentDescription = "Active", tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun AccountDetail(
    npub: String,
    cfg: HavenConfig,
    isOwner: Boolean,
    isActive: Boolean,
    hasLocalKey: Boolean,
    viewModel: AccountSettingsViewModel,
) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val colors = LocalNostrVaultColors.current
    val hasBunker = cfg.bunkerConfig(npub) != null
    var revealed by remember(npub) { mutableStateOf<String?>(null) }
    var confirmRemoveKey by remember(npub) { mutableStateOf(false) }
    var confirmDisconnectSigner by remember(npub) { mutableStateOf(false) }
    var confirmRemoveAccount by remember(npub) { mutableStateOf(false) }

    // Same titles, messages and buttons as iOS (SettingsView.swift).
    if (confirmDisconnectSigner) {
        AlertDialog(
            onDismissRequest = { confirmDisconnectSigner = false },
            title = { Text("Disconnect Remote Signer") },
            text = {
                Text(
                    if (hasLocalKey) {
                        "This drops the remote signer connection and its stored session. Signing falls back to the local key on this device; reconnecting needs a fresh bunker URI."
                    } else {
                        "This drops the remote signer connection and its stored session, and nothing else here can sign for this account afterwards. Reconnecting needs a fresh bunker URI."
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmDisconnectSigner = false
                    viewModel.disconnectSigner(npub)
                }) { Text("Disconnect", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDisconnectSigner = false }) { Text("Cancel") }
            },
        )
    }

    if (confirmRemoveAccount) {
        AlertDialog(
            onDismissRequest = { confirmRemoveAccount = false },
            title = { Text("Remove Account") },
            text = {
                Text("This removes ${npub.take(12)}… from Nostr Vault, along with any key or signer stored for it. Nothing on the relays changes, but you will need the key again to sign back in.")
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmRemoveAccount = false
                    viewModel.removeAccount(npub)
                }) { Text("Remove Account", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmRemoveAccount = false }) { Text("Cancel") }
            },
        )
    }

    if (confirmRemoveKey) {
        AlertDialog(
            onDismissRequest = { confirmRemoveKey = false },
            title = { Text("Remove Local Key") },
            text = {
                Text(
                    if (hasBunker) {
                        "This deletes the private key stored on this device. Signing falls back to the remote signer. If you have no backup of the key elsewhere, it cannot be recovered."
                    } else {
                        "This deletes the private key stored on this device, and nothing else here can sign for this account afterwards. If you have no backup of the key elsewhere, it cannot be recovered."
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmRemoveKey = false
                    revealed = null
                    viewModel.removeLocalKey(npub)
                }) { Text("Remove Key", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmRemoveKey = false }) { Text("Cancel") }
            },
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 52.dp, bottom = 8.dp),
    ) {
        if (!isActive) {
            TextButton(onClick = { viewModel.switchTo(npub) }) {
                Text("Switch to this account", color = colors.primary)
            }
        }

        // Signing-method picker when both local key and bunker exist.
        if (hasLocalKey && hasBunker) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
                Text("Signing", color = SecondaryText, fontSize = 13.sp, modifier = Modifier.weight(1f))
                FilterChip(
                    selected = cfg.signingMode(npub) == "local",
                    onClick = { viewModel.setSigningMode(npub, "local") },
                    label = { Text("Local") },
                )
                Spacer(Modifier.width(6.dp))
                FilterChip(
                    selected = cfg.signingMode(npub) == "nip46",
                    onClick = { viewModel.setSigningMode(npub, "nip46") },
                    label = { Text("Remote") },
                )
            }
        }

        // Local key
        if (hasLocalKey) {
            if (revealed == null) {
                TextButton(onClick = {
                    val activity = context as? FragmentActivity
                    if (activity != null) {
                        authenticateAndReveal(activity) { revealed = viewModel.revealNsec(npub) }
                    } else {
                        revealed = viewModel.revealNsec(npub)
                    }
                }) { Text("Reveal Private Key", color = colors.primary) }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
                    Text(
                        revealed!!,
                        color = PrimaryText,
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = { clipboard.setText(AnnotatedString(revealed!!)) }) {
                        Icon(NostrVaultIcons.Copy, contentDescription = "Copy", tint = SecondaryText, modifier = Modifier.size(16.dp))
                    }
                    IconButton(onClick = { revealed = null }) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Hide", tint = SecondaryText, modifier = Modifier.size(16.dp))
                    }
                }
            }
            TextButton(onClick = { confirmRemoveKey = true }) {
                Text("Remove Local Key", color = ErrorRed)
            }
        }

        // Remote signer
        if (hasBunker) {
            TextButton(onClick = { confirmDisconnectSigner = true }) {
                Text("Disconnect Remote Signer", color = ErrorRed)
            }
        }

        // NIP-65 publish toggle
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
            Text("Publish Inbox Relay (NIP-65)", color = PrimaryText, fontSize = 13.sp, modifier = Modifier.weight(1f))
            Switch(
                checked = cfg.publishRelayListPerAccount[npub] ?: false,
                onCheckedChange = { viewModel.togglePublishRelayList(npub, it) },
                colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = colors.primary),
            )
        }

        if (!isOwner) {
            TextButton(onClick = { confirmRemoveAccount = true }) {
                Text("Remove Account", color = ErrorRed)
            }
        }
    }
}

@Composable
private fun AddAccountSection(viewModel: AccountSettingsViewModel) {
    val colors = LocalNostrVaultColors.current
    var expanded by remember { mutableStateOf(false) }
    var keyInput by remember { mutableStateOf("") }
    var bunkerInput by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    // Remote signers hand out their bunker string as a QR code. Typing one by
    // hand on a phone is the difference between the feature being usable and
    // being theoretical, and the app already scans QR codes in setup and the
    // wallet.
    val bunkerScanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.trim()?.let { scanned ->
            if (scanned.startsWith("bunker://")) {
                bunkerInput = scanned
                error = null
            } else {
                error = "That QR code is not a bunker:// connection string"
            }
        }
    }

    if (!expanded) {
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.fillMaxWidth()) {
            Text("Add Account")
        }
        return
    }

    Text("Add Account", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        value = keyInput,
        onValueChange = { keyInput = it; error = null },
        placeholder = { Text("npub1… or nsec1…") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
            cursorColor = colors.primary, focusedBorderColor = colors.primary,
        ),
    )
    Row(modifier = Modifier.padding(top = 8.dp)) {
        Button(
            onClick = {
                val t = keyInput.trim()
                when {
                    t.startsWith("nsec1") -> {
                        if (viewModel.importKey(t) == null) error = "Invalid nsec"
                        else { keyInput = ""; expanded = false }
                    }
                    t.startsWith("npub1") -> { viewModel.addViewOnly(t); keyInput = ""; expanded = false }
                    else -> error = "Enter an npub or nsec"
                }
            },
            enabled = keyInput.isNotBlank(),
            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
        ) { Text("Add") }
        Spacer(Modifier.width(8.dp))
        TextButton(onClick = { expanded = false }) { Text("Cancel") }
    }

    Spacer(Modifier.height(12.dp))
    Text("Connect Remote Signer (NIP-46)", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    Spacer(Modifier.height(8.dp))
    NostrConnectPairing(
        accent = colors.primary,
        onPaired = { request, signerPubkey ->
            if (viewModel.pairNostrConnect(request, signerPubkey) == null) {
                "Could not connect signer"
            } else {
                expanded = false
                null
            }
        },
    )
    Spacer(Modifier.height(12.dp))
    Text("Or paste a bunker link from any signer app.", color = SecondaryText, fontSize = 12.sp)
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        value = bunkerInput,
        onValueChange = { bunkerInput = it; error = null },
        placeholder = { Text("bunker://…") },
        singleLine = true,
        trailingIcon = {
            IconButton(onClick = {
                bunkerScanner.launch(
                    ScanOptions().apply {
                        setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                        setPrompt("Scan your signer's bunker:// code")
                        setBeepEnabled(false)
                        setOrientationLocked(true)
                    }
                )
            }) {
                Icon(
                    Icons.Default.QrCodeScanner,
                    contentDescription = "Scan bunker QR code",
                    tint = colors.primary,
                )
            }
        },
        modifier = Modifier.fillMaxWidth(),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
            cursorColor = colors.primary, focusedBorderColor = colors.primary,
        ),
    )
    Button(
        onClick = {
            viewModel.connectSigner(bunkerInput.trim()) { result ->
                if (result == null) error = "Could not connect signer"
                else { bunkerInput = ""; expanded = false }
            }
        },
        enabled = bunkerInput.startsWith("bunker://"),
        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
        modifier = Modifier.padding(top = 8.dp),
    ) { Text("Connect") }

    error?.let {
        Spacer(Modifier.height(8.dp))
        Text(it, color = ErrorRed, fontSize = 12.sp)
    }
}

@Composable
private fun Badge2(text: String, color: Color) {
    Surface(color = color.copy(alpha = 0.15f), shape = RoundedCornerShape(6.dp)) {
        Text(
            text,
            color = color,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

private fun colorPrimaryFor(mode: String): Color = when (mode) {
    "owner" -> Color(0xFF9C27B0)
    "amber" -> Color(0xFF4CAF50)
    "nip46" -> Color(0xFF2196F3)
    else -> Color(0xFFF59E0B)
}

/** Prompt biometric/device-credential auth, then run [onSuccess] on success. */
private fun authenticateAndReveal(activity: FragmentActivity, onSuccess: () -> Unit) {
    val executor = ContextCompat.getMainExecutor(activity)
    val prompt = BiometricPrompt(
        activity,
        executor,
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                onSuccess()
            }
        },
    )
    val info = BiometricPrompt.PromptInfo.Builder()
        .setTitle("Authenticate")
        .setSubtitle("Reveal your private key")
        .setAllowedAuthenticators(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL,
        )
        .build()
    prompt.authenticate(info)
}
