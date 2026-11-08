package com.nostrvault.ui.screens.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.QueuedMediaPost
import com.nostrvault.data.model.WaitingPostStopReason
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaPostQueue
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Blossom mirror server configuration.
 * Matches iOS BlossomSettingsView.
 */
@HiltViewModel
class BlossomSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val mediaPostQueue: MediaPostQueue,
    private val blossomService: BlossomService,
) : ViewModel() {

    /** The shared mirror-from-servers run (Mirror Now, dashboard, auto-mirror). */
    val mirrorRun: StateFlow<BlossomService.MirrorRun> = blossomService.mirrorRun

    fun mirrorNow() { blossomService.runMirror() }

    private val _autoMirror = MutableStateFlow(configStore.config.value.autoMirrorMedia)
    val autoMirror = _autoMirror.asStateFlow()

    fun setAutoMirror(enabled: Boolean) {
        _autoMirror.value = enabled
        configStore.update { it.copy(autoMirrorMedia = enabled) }
    }

    /** Posts whose media is on this device but on no outside server yet. */
    val waitingPosts: StateFlow<List<QueuedMediaPost>> = mediaPostQueue.posts

    fun discardWaitingPost(id: String) = mediaPostQueue.discard(id)

    fun retryWaitingPosts() = mediaPostQueue.sendNow()

    /** The list on screen. Nothing here is stored or published until [save] (Logen 2026-11-08). */
    private val _draft = MutableStateFlow(MediaServersDraft(configStore.config.value.blossomMirrors))
    val draft = _draft.asStateFlow()

    private val _newMirrorUrl = MutableStateFlow("")
    val newMirrorUrl = _newMirrorUrl.asStateFlow()

    private val _macRelayHttps = MutableStateFlow<String?>(null)
    val macRelayHttps = _macRelayHttps.asStateFlow()

    private val _publishStatus = MutableStateFlow("")
    val publishStatus = _publishStatus.asStateFlow()

    private fun publishedList() = nostrService.serverLists.value[nostrService.ownerHexPubkey].orEmpty()

    /** Your mobile and desktop vaults, listed in your 10063 or not, as the draft would leave them (MediaServerVaults). */
    val vaults: StateFlow<List<com.nostrvault.fips.MediaServerVault>> =
        kotlinx.coroutines.flow.combine(configStore.config, nostrService.serverLists, _draft) { cfg, lists, draft ->
            com.nostrvault.fips.MediaServerVaults.rows(draft.applyVaults(cfg), lists[nostrService.ownerHexPubkey].orEmpty())
        }.stateIn(viewModelScope, kotlinx.coroutines.flow.SharingStarted.Eagerly, emptyList())

    init {
        val config = configStore.config.value
        _macRelayHttps.value = config.macRelayHttpsURL.takeIf { it.isNotBlank() }
        // What the published list holds now, for the vaults' Add / Take off.
        nostrService.ownerHexPubkey.takeIf { it.isNotEmpty() }?.let { nostrService.fetchServerList(it) }
        // Another device's list adopted while this screen is open: follow it unless there are unsaved edits.
        viewModelScope.launch {
            configStore.config.collect { cfg -> _draft.value = _draft.value.savedMirrorsChanged(cfg.blossomMirrors) }
        }
    }

    /** "Add to my media servers" ([list] true) or "Take off": changes the list on screen only. */
    fun setVaultListed(npub: String, list: Boolean) {
        val listedNow = com.nostrvault.fips.MediaServerVaults.rows(configStore.config.value, publishedList())
            .firstOrNull { it.npub == npub }?.listed ?: false
        _draft.value = _draft.value.setVault(npub, list, listedNow)
    }

    fun setNewMirrorUrl(url: String) { _newMirrorUrl.value = url }

    fun addMirror() {
        val before = _draft.value
        _draft.value = before.addMirror(_newMirrorUrl.value)
        if (_draft.value != before) _newMirrorUrl.value = ""
    }

    /** Media Servers › Suggested. Leaves a half-typed address alone. */
    fun addSuggested(url: String) { _draft.value = _draft.value.addMirror(url) }

    fun removeMirror(url: String) { _draft.value = _draft.value.removeMirror(url) }

    /** Save: store the typed servers and the vault choices, then publish the 10063 once. */
    fun save() {
        val draft = _draft.value
        if (!draft.hasChanges) return
        configStore.update { draft.saveInto(it, System.currentTimeMillis() / 1000) }
        _draft.value = draft.saved()
        try {
            _publishStatus.value = "Server list published"
            // Nothing goes out over a list that isn't known (no relay list, or the relays didn't answer): say why.
            nostrService.publishServerList(onRefused = { why -> _publishStatus.value = "Not published. $why" })
        } catch (e: Exception) {
            _publishStatus.value = "Failed to publish: ${e.message}"
        }
    }

    /** Discard: back to the saved list; nothing stored or published. */
    fun discard() { _draft.value = _draft.value.discarded() }

    fun dismissStatus() {
        _publishStatus.value = ""
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BlossomSettingsScreen(
    onBack: () -> Unit,
    onOpenFipsMesh: () -> Unit = {},
    viewModel: BlossomSettingsViewModel = hiltViewModel(),
) {
    val draft by viewModel.draft.collectAsState()
    val mirrors = draft.mirrors
    val changes = draft.changeCount
    val newMirrorUrl by viewModel.newMirrorUrl.collectAsState()
    val macRelayHttps by viewModel.macRelayHttps.collectAsState()
    val publishStatus by viewModel.publishStatus.collectAsState()
    val waitingPosts by viewModel.waitingPosts.collectAsState()
    val mirrorRun by viewModel.mirrorRun.collectAsState()
    val autoMirror by viewModel.autoMirror.collectAsState()
    val vaults by viewModel.vaults.collectAsState()
    val colors = LocalNostrVaultColors.current
    var leaving by remember { mutableStateOf(false) }

    // Leaving with unsaved changes asks Save or Discard: nothing is stored or published without Save.
    BackHandler(enabled = changes > 0) { leaving = true }
    val back = { if (changes > 0) leaving = true else onBack() }
    val offlineCopies: @Composable () -> Unit = {
        OfflineCopiesSection(
            run = mirrorRun,
            hasMirrors = mirrors.isNotEmpty() || !macRelayHttps.isNullOrBlank(),
            autoMirror = autoMirror,
            onMirrorNow = viewModel::mirrorNow,
            onAutoMirrorChange = viewModel::setAutoMirror,
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Media Servers") },
                navigationIcon = {
                    IconButton(onClick = back) {
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
        bottomBar = { MediaServersSaveBar(changes, colors.primary, viewModel::save) },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            // Posts whose media is on this device but on no outside server
            // yet. They send themselves; this is where the user can see them.
            if (waitingPosts.isNotEmpty()) {
                WaitingPostsSection(
                    posts = waitingPosts,
                    onDiscard = viewModel::discardWaitingPost,
                    onRetry = viewModel::retryWaitingPosts,
                )
                HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            }

            // Auto-applied server from Haven relay
            if (!macRelayHttps.isNullOrBlank()) {
                Surface(
                    color = SuccessGreen.copy(alpha = 0.1f),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            NostrVaultIcons.Check,
                            contentDescription = null,
                            tint = SuccessGreen,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Column {
                            Text(
                                text = "Auto-Applied Blossom Server",
                                color = PrimaryText,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                text = macRelayHttps!!,
                                color = SecondaryText,
                                fontSize = 12.sp,
                            )
                        }
                    }
                }
            }

            // Every server plain http: uploads and their auth headers go out unencrypted (Tron #1451).
            if (com.nostrvault.service.ServerListAdoption.allPlainHttp(mirrors)) {
                Surface(
                    color = WarningYellow.copy(alpha = 0.1f),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 4.dp),
                ) {
                    Text(
                        text = "These servers use http, not https. Uploads and their sign-in go out unencrypted. Add an https server to keep them private.",
                        color = WarningYellow,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                }
            }

            // Publish status
            if (publishStatus.isNotBlank()) {
                Surface(
                    color = SuccessGreen.copy(alpha = 0.1f),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 4.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    ) {
                        Icon(
                            NostrVaultIcons.Check,
                            contentDescription = null,
                            tint = SuccessGreen,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = publishStatus,
                            color = SuccessGreen,
                            fontSize = 12.sp,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = viewModel::dismissStatus) {
                            Text("OK", color = SecondaryText, fontSize = 11.sp)
                        }
                    }
                }
            }

            // Section header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp),
            ) {
                Text(
                    text = "ADDITIONAL BLOSSOM SERVERS",
                    color = SecondaryText,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.sp,
                )
                InfoButton(SettingsHelp.SHARE_MEDIA_SERVERS)
            }

            // Add mirror input
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                OutlinedTextField(
                    value = newMirrorUrl,
                    onValueChange = viewModel::setNewMirrorUrl,
                    placeholder = { Text("https://blossom.example.com") },
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
                    onClick = viewModel::addMirror,
                    enabled = newMirrorUrl.isNotBlank(),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Create,
                        contentDescription = "Add",
                        tint = if (newMirrorUrl.isNotBlank()) colors.primary else TertiaryText,
                    )
                }
            }

            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

            LazyColumn(modifier = Modifier.fillMaxSize()) {
                if (mirrors.isEmpty()) {
                    item {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(32.dp),
                        ) {
                            Text("No additional mirrors configured", color = SecondaryText, fontSize = 15.sp)
                        }
                    }
                } else {
                    items(mirrors) { mirror ->
                        MirrorRow(
                            url = mirror,
                            onRemove = { viewModel.removeMirror(mirror) },
                        )
                        HorizontalDivider(
                            color = SeparatorColor,
                            thickness = 0.5.dp,
                            modifier = Modifier.padding(start = 16.dp),
                        )
                    }
                }
                if (vaults.isNotEmpty()) item { YourVaultsSection(vaults, viewModel::setVaultListed) }
                item { SuggestedMediaServersSection(mirrors, viewModel::addSuggested) }
                item { offlineCopies() }
                item { FipsSection(onOpenFipsMesh) }
            }
        }
    }

    if (leaving) {
        AlertDialog(
            onDismissRequest = { leaving = false },
            title = { Text("Save ${changes.changesLabel()}?") },
            text = { Text("Your media server list is not published until you save.") },
            confirmButton = {
                TextButton(onClick = { leaving = false; viewModel.save(); onBack() }) { Text("Save", color = colors.primary) }
            },
            dismissButton = {
                TextButton(onClick = { leaving = false; viewModel.discard(); onBack() }) { Text("Discard", color = ErrorRed) }
            },
        )
    }
}

/** Save at the foot of Media Servers: the one place the 10063 goes out. */
@Composable
private fun MediaServersSaveBar(changes: Int, accent: androidx.compose.ui.graphics.Color, onSave: () -> Unit) {
    Column(Modifier.fillMaxWidth().background(Surface1).navigationBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp)) {
        Button(
            onClick = onSave,
            enabled = changes > 0,
            colors = ButtonDefaults.buttonColors(containerColor = accent),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (changes == 0) "No changes" else "Save (${changes.changesLabel()})", fontWeight = FontWeight.SemiBold)
        }
        Text("Adding or taking off a server only changes this list. Save publishes it.",
            color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
    }
}

/**
 * "Mesh": how to reach media on .fips servers. The mesh is built into the app, not a VPN, so there is no
 * VPN status row (iOS dropped its own, b8a13e558). Same as the iOS Media Servers screen.
 * Your own mesh lives in Settings → FIPS Mesh: one link to it here.
 */
internal const val FIPS_SERVERS_TEXT =
    "To load media from a .fips server, turn on Mesh, then add the server's .fips address under Additional Blossom Servers above."

@Composable
private fun FipsSection(onOpenFipsMesh: () -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp, bottom = 8.dp)) {
            Text(
                text = "Mesh",
                color = SecondaryText,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.sp,
            )
            InfoButton(SettingsHelp.SHARE_FIPS)
        }
        Surface(color = SecondaryGroupedBg, shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    FIPS_SERVERS_TEXT,
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
                Text(
                    "Your own devices and sharing: Mesh",
                    color = LocalNostrVaultColors.current.primary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable(onClick = onOpenFipsMesh),
                )
            }
        }
    }
}

/**
 * "Offline Copies": Mirror from Servers (Mirror Now) and the Auto-Mirror
 * Media switch, as in iOS BlossomSettingsView.
 */
@Composable
private fun OfflineCopiesSection(
    run: BlossomService.MirrorRun,
    hasMirrors: Boolean,
    autoMirror: Boolean,
    onMirrorNow: () -> Unit,
    onAutoMirrorChange: (Boolean) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "OFFLINE COPIES",
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.sp,
            modifier = Modifier.padding(start = 16.dp, top = 24.dp, bottom = 8.dp),
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("Mirror from Servers", color = PrimaryText, fontSize = 15.sp)
                Text(
                    text = when {
                        run.running -> run.status
                        run.lastResult.isNotEmpty() -> run.lastResult
                        else -> "Download your media from your media servers into your vault"
                    },
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
            }
            Spacer(Modifier.width(8.dp))
            Button(
                onClick = onMirrorNow,
                enabled = !run.running && hasMirrors,
                shape = RoundedCornerShape(6.dp),
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
            ) {
                if (run.running) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                        color = PrimaryText,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(run.progress?.let { "${(it * 100).toInt()}%" } ?: "Mirroring", fontSize = 13.sp)
                } else {
                    Text("Mirror Now", fontSize = 13.sp)
                }
            }
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 8.dp, top = 4.dp, bottom = 16.dp),
        ) {
            Text("Auto-Mirror Media", color = PrimaryText, fontSize = 15.sp)
            InfoButton(SettingsHelp.SHARE_AUTO_MIRROR)
            Spacer(Modifier.weight(1f))
            Switch(
                checked = autoMirror,
                onCheckedChange = onAutoMirrorChange,
                colors = SwitchDefaults.colors(checkedTrackColor = colors.primary),
            )
        }
    }
}

/** Under Your Vaults: how a vault gets on the list, and that nothing else puts it there. */
internal const val YOUR_VAULTS_FOOTER = "Readers can fetch your photos from a vault you add here, over the mesh. " +
    "Linking or removing a vault in Mesh does not change this list; only your choice here does."

/**
 * "Your Vaults": the owner's mobile and desktop vaults, each with "Add to my media servers" or "Take off"
 * (Logen 2026-11-08). Phones and the browser vault are never listed here.
 */
@Composable
private fun YourVaultsSection(vaults: List<com.nostrvault.fips.MediaServerVault>, onChoose: (String, Boolean) -> Unit) {
    val colors = LocalNostrVaultColors.current
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "YOUR VAULTS",
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.sp,
            modifier = Modifier.padding(start = 16.dp, top = 24.dp, bottom = 8.dp),
        )
        vaults.forEach { v ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(v.title, color = PrimaryText, fontSize = 15.sp, maxLines = 1)
                    Text(if (v.listed) "${v.kind} · in your media servers" else v.kind, color = SecondaryText, fontSize = 12.sp)
                }
                if (v.listed) {
                    TextButton(onClick = { onChoose(v.npub, false) }) { Text("Take off", color = ErrorRed, fontSize = 13.sp) }
                } else {
                    TextButton(onClick = { onChoose(v.npub, true) }) { Text("Add to my media servers", color = colors.primary, fontSize = 13.sp) }
                }
            }
            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp, modifier = Modifier.padding(start = 16.dp))
        }
        Text(
            YOUR_VAULTS_FOOTER,
            color = SecondaryText,
            fontSize = 12.sp,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun MirrorRow(
    url: String,
    onRemove: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Blossom,
            contentDescription = null,
            tint = LocalNostrVaultColors.current.primary,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = url.removePrefix("https://"),
            color = PrimaryText,
            fontSize = 15.sp,
            modifier = Modifier.weight(1f),
        )
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

@Composable
private fun WaitingPostsSection(
    posts: List<QueuedMediaPost>,
    onDiscard: (String) -> Unit,
    onRetry: () -> Unit,
) {
    val dateFormat = remember {
        java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT)
    }
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "WAITING TO SEND",
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.sp,
            modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp),
        )
        // A handful at most in practice; a plain Column keeps the screen's
        // single LazyColumn (the mirror list) as the only scrolling child.
        posts.forEach { post ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.History,
                    contentDescription = null,
                    tint = ZapOrange,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = post.body.ifBlank { "Post with ${post.media.size} attachment(s)" },
                        color = PrimaryText,
                        fontSize = 15.sp,
                        maxLines = 2,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    )
                    Text(
                        text = "Waiting for a media server since ${dateFormat.format(java.util.Date(post.createdAt))}",
                        color = SecondaryText,
                        fontSize = 12.sp,
                    )
                    WaitingPostStopReason.of(post)?.let { reason ->
                        Text(text = reason, color = ErrorRed, fontSize = 12.sp)
                    }
                }
                IconButton(onClick = { onDiscard(post.id) }) {
                    Icon(
                        imageVector = NostrVaultIcons.Delete,
                        contentDescription = "Discard waiting post",
                        tint = ErrorRed,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
        TextButton(
            onClick = onRetry,
            modifier = Modifier.padding(horizontal = 8.dp),
        ) {
            Text("Try sending now", color = LocalNostrVaultColors.current.primary)
        }
        Text(
            text = "The photos are saved on this device. These posts send themselves as soon as a media server below answers.",
            color = SecondaryText,
            fontSize = 12.sp,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
        )
    }
}
