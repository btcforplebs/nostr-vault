package com.nostrvault.ui.screens.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.fips.FipsMeshManager
import com.nostrvault.fips.FipsStatus
import com.nostrvault.fips.HomeVaultRules
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class MeshSettingsViewModel @Inject constructor(
    private val mesh: FipsMeshManager,
    private val nostrService: NostrService,
    private val homeVault: HomeVaultSender,
) : ViewModel() {

    val status = mesh.status
    val lastError = mesh.lastError
    val isAvailable = mesh.isAvailable

    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()

    init {
        viewModelScope.launch { mesh.refresh() }
        // The owner's 10063 names their mesh vaults; make sure it is fresh.
        nostrService.ownerHexPubkey.takeIf { it.isNotEmpty() }?.let { nostrService.fetchServerList(it) }
    }

    /** The owner's own vaults on the mesh, other than this phone. */
    val homeVaultCandidates = combine(nostrService.serverLists, mesh.status) { lists, status ->
        HomeVaultRules.candidates(lists[nostrService.ownerHexPubkey].orEmpty(), status.npub)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _homeVaultNpub = MutableStateFlow(homeVault.homeVaultNpub)
    val homeVaultNpub = _homeVaultNpub.asStateFlow()
    val homeVaultState = homeVault.state

    fun setHomeVault(npub: String?) {
        val before = _homeVaultNpub.value
        if (npub != null && npub == mesh.status.value.npub) return  // this phone itself
        _homeVaultNpub.value = npub
        viewModelScope.launch {
            homeVault.setHomeVault(npub)
            // This phone lists its home vault in the owner's 10063: the kiosk
            // needs no key. A changed setting drops the old entry.
            nostrService.publishServerList(dropMesh = before?.takeIf { it != npub })
        }
    }

    fun sendHomeVaultNow() = homeVault.drainSoon(userInitiated = true)

    val shareRelay = mesh.shareRelay
    val peers = mesh.peers
    val serveLimit = mesh.serveLimitBytes

    fun setServeLimit(bytes: Long) {
        viewModelScope.launch { mesh.setServeLimit(bytes) }
    }

    fun addPeer(npub: String) = updatePeers { it + npub }

    fun removePeer(npub: String) = updatePeers { it - npub }

    private fun updatePeers(change: (List<String>) -> List<String>) {
        if (_busy.value) return
        viewModelScope.launch {
            _busy.value = true
            mesh.setPeers(change(peers.value))
            _busy.value = false
        }
    }

    fun setShareRelay(enabled: Boolean) {
        if (_busy.value) return
        viewModelScope.launch {
            _busy.value = true
            mesh.setShareRelay(enabled)
            _busy.value = false
        }
    }

    fun setEnabled(enabled: Boolean) {
        if (_busy.value) return
        viewModelScope.launch {
            _busy.value = true
            if (enabled) mesh.start() else mesh.stop()
            _busy.value = false
        }
    }

    suspend fun refresh() = mesh.refresh()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MeshSettingsScreen(
    onBack: () -> Unit,
    viewModel: MeshSettingsViewModel = hiltViewModel(),
) {
    val status by viewModel.status.collectAsState()
    val lastError by viewModel.lastError.collectAsState()
    val busy by viewModel.busy.collectAsState()
    val shareRelay by viewModel.shareRelay.collectAsState()
    val peers by viewModel.peers.collectAsState()
    val homeVaultCandidates by viewModel.homeVaultCandidates.collectAsState()
    val homeVaultNpub by viewModel.homeVaultNpub.collectAsState()
    val homeVaultState by viewModel.homeVaultState.collectAsState()
    val serveLimit by viewModel.serveLimit.collectAsState()
    val colors = LocalNostrVaultColors.current
    val clipboard = LocalClipboardManager.current

    // Polled, not pushed: the bridge never calls back into the JVM, so uptime
    // and state are read while this screen is on top and nowhere else.
    LaunchedEffect(status.running) {
        while (status.running) {
            delay(2000)
            viewModel.refresh()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Mesh") },
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
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(16.dp))

            if (!viewModel.isAvailable) {
                Notice(
                    text = "This build does not include the mesh library for your " +
                        "device's processor, so the mesh cannot be turned on here.",
                    tint = SecondaryText,
                )
                Spacer(Modifier.height(16.dp))
            }

            Text(
                text = "FIPS MESH",
                color = SecondaryText,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.sp,
                modifier = Modifier.padding(bottom = 8.dp),
            )

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        "Broadcast my address",
                        color = PrimaryText,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    Text(
                        "Announce this device on the mesh so peers can dial it.",
                        color = SecondaryText,
                        fontSize = 13.sp,
                        lineHeight = 18.sp,
                    )
                }
                Spacer(Modifier.width(12.dp))
                if (busy) {
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        color = colors.primary,
                        modifier = Modifier.size(24.dp),
                    )
                } else {
                    Switch(
                        checked = status.running,
                        onCheckedChange = viewModel::setEnabled,
                        enabled = viewModel.isAvailable,
                        colors = SwitchDefaults.colors(checkedTrackColor = colors.primary),
                    )
                }
            }

            if (status.running) {
                Spacer(Modifier.height(20.dp))
                AddressCard(
                    status = status,
                    onCopy = { clipboard.setText(AnnotatedString(it)) },
                )
            }

            Spacer(Modifier.height(12.dp))
            PeopleCard(
                peers = peers,
                connected = status.peers,
                enabled = viewModel.isAvailable && !busy,
                onAdd = viewModel::addPeer,
                onRemove = viewModel::removePeer,
            )

            Spacer(Modifier.height(20.dp))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        "Share my relay",
                        color = PrimaryText,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    Text(
                        // Separate switch on purpose: being findable and being
                        // reachable are different decisions to make.
                        if (status.exported.isEmpty()) {
                            "Let mesh peers reach this device's relay and media."
                        } else {
                            "Offered on the mesh: port ${status.exported.joinToString()}."
                        },
                        color = SecondaryText,
                        fontSize = 13.sp,
                        lineHeight = 18.sp,
                    )
                }
                Spacer(Modifier.width(12.dp))
                Switch(
                    checked = shareRelay,
                    onCheckedChange = viewModel::setShareRelay,
                    enabled = viewModel.isAvailable && !busy,
                    colors = SwitchDefaults.colors(checkedTrackColor = colors.primary),
                )
            }

            Spacer(Modifier.height(12.dp))
            Text("Stop sharing after", color = SecondaryText, fontSize = 13.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((bytes, label) in SERVE_LIMITS) {
                    FilterChip(
                        selected = serveLimit == bytes,
                        onClick = { viewModel.setServeLimit(bytes) },
                        // Applies at the next start, so it is fixed while sharing.
                        enabled = !shareRelay && !busy,
                        label = { Text(label) },
                    )
                }
            }
            Text(
                "Sharing stops once the mesh has downloaded this much. One visitor gets at most 256 MB of it.",
                color = SecondaryText,
                fontSize = 13.sp,
                lineHeight = 18.sp,
            )

            Spacer(Modifier.height(20.dp))
            HomeVaultCard(
                candidates = homeVaultCandidates,
                selected = homeVaultNpub,
                state = homeVaultState,
                enabled = viewModel.isAvailable,
                onSelect = viewModel::setHomeVault,
                onSendNow = viewModel::sendHomeVaultNow,
            )

            lastError?.let { error ->
                Spacer(Modifier.height(16.dp))
                Notice(text = error, tint = ErrorRed)
            }

            Spacer(Modifier.height(20.dp))

            Text(
                // Said plainly on the screen because it is the difference
                // between "my address is published" and "someone can reach me".
                text = "While this is on, your mesh address is published to Nostr " +
                    "relays, and devices find each other through them and connect " +
                    "directly. Only the people listed above can connect to you.",
                color = SecondaryText,
                fontSize = 13.sp,
                lineHeight = 18.sp,
            )

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun AddressCard(status: FipsStatus, onCopy: (String) -> Unit) {
    Surface(
        color = CardBackground,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp)) {
            Text("YOUR MESH ADDRESS", color = SecondaryText, fontSize = 11.sp, letterSpacing = 1.sp)
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = status.npub ?: "—",
                    color = PrimaryText,
                    fontSize = 13.sp,
                    fontFamily = FontFamily.Monospace,
                    lineHeight = 18.sp,
                    modifier = Modifier.weight(1f),
                )
                status.npub?.let { npub ->
                    IconButton(onClick = { onCopy(npub) }) {
                        Icon(
                            NostrVaultIcons.Copy,
                            contentDescription = "Copy mesh address",
                            tint = SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }

            status.npub?.let { npub ->
                // Another phone scans this under Home vault.
                val qr = remember(npub) {
                    runCatching { BarcodeEncoder().encodeBitmap("fipsmesh://$npub/", BarcodeFormat.QR_CODE, 480, 480) }.getOrNull()
                }
                qr?.let {
                    Spacer(Modifier.height(8.dp))
                    Image(
                        bitmap = it.asImageBitmap(),
                        contentDescription = "Mesh address QR code",
                        modifier = Modifier
                            .size(160.dp)
                            .background(Color.White, RoundedCornerShape(6.dp))
                            .padding(6.dp),
                    )
                }
            }

            status.address?.let { address ->
                Spacer(Modifier.height(10.dp))
                Text("MESH IP", color = SecondaryText, fontSize = 11.sp, letterSpacing = 1.sp)
                Spacer(Modifier.height(4.dp))
                Text(
                    text = address,
                    color = SecondaryText,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }

            Spacer(Modifier.height(10.dp))
            Text(
                text = "Up ${formatUptime(status.uptimeSeconds)}",
                color = SuccessGreen,
                fontSize = 12.sp,
            )
        }
    }
}

/**
 * The people allowed to reach this device. Nobody else can: the mesh runs a
 * configured-only policy, so this list is the whole door.
 */
@Composable
private fun PeopleCard(
    peers: List<String>,
    connected: List<String>,
    enabled: Boolean,
    onAdd: (String) -> Unit,
    onRemove: (String) -> Unit,
) {
    var draft by remember { mutableStateOf("") }
    val draftValid = draft.trim().startsWith("npub1") && draft.trim().length == 63

    Surface(
        color = CardBackground,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp)) {
            Text("WHO CAN REACH YOU", color = SecondaryText, fontSize = 11.sp, letterSpacing = 1.sp)
            Spacer(Modifier.height(8.dp))

            if (peers.isEmpty()) {
                Text(
                    "Nobody yet. Add a friend's mesh address to let them in.",
                    color = SecondaryText,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                )
            }
            peers.forEach { npub ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(vertical = 3.dp),
                ) {
                    Text(
                        text = npub.take(12) + "…" + npub.takeLast(6),
                        color = PrimaryText,
                        fontSize = 13.sp,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        if (npub in connected) "connected" else "not connected",
                        color = if (npub in connected) SuccessGreen else SecondaryText,
                        fontSize = 12.sp,
                    )
                    TextButton(onClick = { onRemove(npub) }, enabled = enabled) {
                        Text("Remove", fontSize = 12.sp)
                    }
                }
            }

            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                singleLine = true,
                placeholder = { Text("npub1…", fontSize = 13.sp) },
                textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(6.dp))
            Button(
                onClick = { onAdd(draft.trim()); draft = "" },
                enabled = enabled && draftValid,
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) { Text("Add") }
        }
    }
}

/**
 * Pick which mesh vault (a kiosk phone) also gets the owner's posts and
 * media: one already in the owner's 10063, or a mesh address pasted or
 * scanned from the kiosk. This phone then lists it, so the kiosk needs no key.
 */
@Composable
private fun HomeVaultCard(
    candidates: List<String>,
    selected: String?,
    state: HomeVaultSender.State,
    enabled: Boolean,
    onSelect: (String?) -> Unit,
    onSendNow: () -> Unit,
) {
    var draft by remember { mutableStateOf("") }
    val draftNpub = remember(draft) { HomeVaultRules.meshNpubFromInput(draft) }
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.trim()?.let { code ->
            draft = code
            HomeVaultRules.meshNpubFromInput(code)?.let { onSelect(it); draft = "" }
        }
    }
    Surface(
        color = CardBackground,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp)) {
            Text("HOME VAULT", color = SecondaryText, fontSize = 11.sp, letterSpacing = 1.sp)
            Spacer(Modifier.height(6.dp))
            Text(
                "Also send your posts and media to another of your devices on the " +
                    "mesh, like a phone in kiosk mode. It keeps them and passes your " +
                    "posts on to the regular relays. This phone keeps its copy too. " +
                    "Direct-message attachments are never sent there.",
                color = SecondaryText,
                fontSize = 13.sp,
                lineHeight = 18.sp,
            )
            Spacer(Modifier.height(8.dp))

            // A chosen vault stays listed even if it has left the 10063 for now
            // (kiosk mode off): what waits for it still goes when it is back.
            val options = (listOfNotNull(selected) + candidates).distinct()
            if (options.isEmpty()) {
                Text(
                    "Turn on kiosk mode on the other device, then scan or paste " +
                        "the mesh address it shows.",
                    color = SecondaryText,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                )
            }
            HomeVaultOption("Off", selected == null, enabled) { onSelect(null) }
            options.forEach { npub ->
                HomeVaultOption(
                    label = npub.take(12) + "…" + npub.takeLast(6) +
                        if (npub in candidates) "" else " (not on the mesh now)",
                    checked = npub == selected,
                    enabled = enabled,
                ) { onSelect(npub) }
            }

            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                singleLine = true,
                enabled = enabled,
                placeholder = { Text("Paste a kiosk's mesh address", fontSize = 13.sp) },
                isError = draft.isNotBlank() && draftNpub == null,
                textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                trailingIcon = {
                    IconButton(onClick = {
                        scanner.launch(
                            ScanOptions().apply {
                                setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                setPrompt("Scan the kiosk's mesh address")
                                setBeepEnabled(false)
                                setOrientationLocked(true)
                            },
                        )
                    }, enabled = enabled) {
                        Icon(Icons.Default.QrCodeScanner, contentDescription = "Scan the kiosk's QR code", tint = SecondaryText)
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
            if (draft.isNotBlank()) {
                if (draftNpub == null) {
                    Text("That isn't a mesh address. Copy it from the kiosk's mesh settings.", color = ErrorRed, fontSize = 12.sp)
                } else {
                    TextButton(onClick = { onSelect(draftNpub); draft = "" }, enabled = enabled) {
                        Text("Use this address", fontSize = 13.sp)
                    }
                }
            }
            Text(
                "Picking a home vault lists its mesh address in your Blossom server " +
                    "list, in public. The kiosk must let your account write to its relay.",
                color = SecondaryText,
                fontSize = 12.sp,
                lineHeight = 16.sp,
            )

            if (selected != null) {
                Spacer(Modifier.height(8.dp))
                Text(
                    when {
                        state.waiting > 0 -> "${state.waiting} waiting to send" +
                            (state.lastProblem?.let { " — $it" } ?: "")
                        state.lastSentAt != null -> "Everything sent"
                        else -> "Nothing to send yet"
                    },
                    color = if (state.waiting > 0) SecondaryText else SuccessGreen,
                    fontSize = 13.sp,
                )
                if (state.publicPending > 0) {
                    Text(
                        "${state.publicPending} on the home vault only. Other apps see " +
                            "${if (state.publicPending == 1) "it" else "them"} once a public server takes a copy.",
                        color = SecondaryText,
                        fontSize = 13.sp,
                        lineHeight = 18.sp,
                    )
                }
                if (state.waiting > 0 || state.publicPending > 0) {
                    TextButton(onClick = onSendNow, enabled = enabled) { Text("Send now", fontSize = 13.sp) }
                }
            }
        }
    }
}

@Composable
private fun HomeVaultOption(label: String, checked: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        RadioButton(selected = checked, onClick = onClick, enabled = enabled)
        Text(
            label,
            color = PrimaryText,
            fontSize = 13.sp,
            fontFamily = if (label == "Off") FontFamily.Default else FontFamily.Monospace,
        )
    }
}

@Composable
private fun Notice(text: String, tint: androidx.compose.ui.graphics.Color) {
    Surface(
        color = tint.copy(alpha = 0.1f),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = text,
            color = tint,
            fontSize = 13.sp,
            lineHeight = 18.sp,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        )
    }
}

internal fun formatUptime(seconds: Long): String = when {
    seconds < 60 -> "${seconds}s"
    seconds < 3600 -> "${seconds / 60}m ${seconds % 60}s"
    else -> "${seconds / 3600}h ${(seconds % 3600) / 60}m"
}

/** The limits offered for one sharing session, as in the iOS kiosk picker. */
private val SERVE_LIMITS = listOf(250L shl 20 to "250 MB", 1L shl 30 to "1 GB", 5L shl 30 to "5 GB")
