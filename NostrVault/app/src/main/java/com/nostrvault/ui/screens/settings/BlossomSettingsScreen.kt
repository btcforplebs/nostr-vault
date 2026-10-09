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
import com.nostrvault.data.model.QueuedMediaPost
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaPostQueue
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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

    fun retryWaitingPosts() = mediaPostQueue.retryAll("user")

    private val _mirrors = MutableStateFlow<List<String>>(emptyList())
    val mirrors = _mirrors.asStateFlow()

    private val _newMirrorUrl = MutableStateFlow("")
    val newMirrorUrl = _newMirrorUrl.asStateFlow()

    private val _macRelayHttps = MutableStateFlow<String?>(null)
    val macRelayHttps = _macRelayHttps.asStateFlow()

    private val _publishStatus = MutableStateFlow("")
    val publishStatus = _publishStatus.asStateFlow()

    init {
        val config = configStore.config.value
        _mirrors.value = config.blossomMirrors
        _macRelayHttps.value = config.macRelayHttpsURL.takeIf { it.isNotBlank() }
    }

    fun setNewMirrorUrl(url: String) { _newMirrorUrl.value = url }

    fun addMirror() {
        val url = _newMirrorUrl.value.trim().let {
            if (!it.startsWith("https://") && !it.startsWith("http://")) "https://$it" else it
        }
        if (url.isBlank()) return
        if (url in _mirrors.value) return

        _mirrors.value = _mirrors.value + url
        _newMirrorUrl.value = ""
        saveAndPublish()
    }

    fun removeMirror(url: String) {
        _mirrors.value = _mirrors.value - url
        saveAndPublish()
    }

    private fun saveAndPublish() {
        viewModelScope.launch {
            configStore.update { it.copy(blossomMirrors = _mirrors.value) }
            try {
                nostrService.publishServerList()
                _publishStatus.value = "Server list published"
            } catch (e: Exception) {
                _publishStatus.value = "Failed to publish: ${e.message}"
            }
        }
    }

    fun dismissStatus() {
        _publishStatus.value = ""
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BlossomSettingsScreen(
    onBack: () -> Unit,
    viewModel: BlossomSettingsViewModel = hiltViewModel(),
) {
    val mirrors by viewModel.mirrors.collectAsState()
    val newMirrorUrl by viewModel.newMirrorUrl.collectAsState()
    val macRelayHttps by viewModel.macRelayHttps.collectAsState()
    val publishStatus by viewModel.publishStatus.collectAsState()
    val waitingPosts by viewModel.waitingPosts.collectAsState()
    val mirrorRun by viewModel.mirrorRun.collectAsState()
    val autoMirror by viewModel.autoMirror.collectAsState()
    val colors = LocalNostrVaultColors.current
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
                title = { Text("Blossom Servers") },
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
            Text(
                text = "ADDITIONAL BLOSSOM SERVERS",
                color = SecondaryText,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.sp,
                modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp),
            )

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

            if (mirrors.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(32.dp),
                ) {
                    Text("No additional mirrors configured", color = SecondaryText, fontSize = 15.sp)
                }
                offlineCopies()
            } else {
                LazyColumn(modifier = Modifier.fillMaxSize()) {
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
                    item { offlineCopies() }
                }
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
                        else -> "Download your media from external Blossom mirrors to local storage"
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
