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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.AvatarImage
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import com.nostrvault.data.model.FollowingSnapshot
import com.nostrvault.data.model.FollowingSnapshotStore
import com.nostrvault.data.model.Kind3Event
import com.nostrvault.service.FeedService
import com.nostrvault.service.FollowingBackupService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.inject.Inject

/**
 * Screen showing following list snapshots.
 * Tap a snapshot to see which pubkeys were added/removed compared to current following.
 */

@HiltViewModel
class FollowingBackupViewModel @Inject constructor(
    private val followingBackupService: FollowingBackupService,
    private val feedService: FeedService,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) : ViewModel() {

    /** Every account on the device, owner first. The picker shows when there's more than one. */
    val accounts: List<String> get() = configStore.config.value.allAccountNpubs()
    val ownerNpub: String get() = configStore.config.value.ownerNpub
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private val activeNpub: String
        get() = configStore.config.value.activeAccountNpub ?: configStore.config.value.ownerNpub

    private val _selectedNpub = MutableStateFlow(activeNpub)
    /** The account whose backups are shown (iOS FollowingBackupSettingsView). */
    val selectedNpub = _selectedNpub.asStateFlow()

    /** Restore and Re-follow change the active account's list, so they only show for it. */
    val isViewingActiveAccount: Boolean get() = _selectedNpub.value == activeNpub
    fun isActive(npub: String): Boolean = npub == activeNpub

    private var scanJob: Job? = null

    fun profileFor(npub: String): FeedProfile? = HavenBridge.decodeNpub(npub)?.let { profiles.value[it] }

    fun ensureProfiles() {
        val hexes = accounts.mapNotNull { HavenBridge.decodeNpub(it) }
        if (hexes.isNotEmpty()) nostrService.fetchMissingProfiles(hexes)
    }

    /** Shows [npub]'s snapshots and drops the last scan, which was another account's. */
    fun selectAccount(npub: String) {
        if (npub == _selectedNpub.value) return
        _selectedNpub.value = npub
        scanJob?.cancel()
        _isScanning.value = false
        _scannedEvents.value = emptyList()
    }

    /**
     * The selected account's snapshots, read from its own file. The service's
     * shared list follows the active account (new snapshots land there), so
     * it re-reads whenever that list changes.
     */
    val snapshots: StateFlow<List<FollowingSnapshot>> =
        combine(_selectedNpub, followingBackupService.snapshots) { npub, _ -> followingBackupService.snapshotsFor(npub) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, followingBackupService.snapshotsFor(_selectedNpub.value))

    private val _scannedEvents = MutableStateFlow<List<Kind3Event>>(emptyList())
    val scannedEvents = _scannedEvents.asStateFlow()

    private val _isScanning = MutableStateFlow(false)
    val isScanning = _isScanning.asStateFlow()

    val currentFollowingCount: Int
        get() = feedService.followedPubkeys.value.size

    val currentFollowedPubkeys: List<String>
        get() = feedService.followedPubkeys.value.toList()

    /** Live follows, so a Re-follow turns into a checkmark (iOS currentSet). */
    val followedPubkeys: StateFlow<List<String>> = feedService.followedPubkeys

    /** Names and avatars for the people a snapshot diff lists. */
    fun fetchProfiles(pubkeys: List<String>) {
        if (pubkeys.isNotEmpty()) nostrService.fetchMissingProfiles(pubkeys)
    }


    fun scanRelays() {
        if (_isScanning.value) return
        val hex = HavenBridge.decodeNpub(_selectedNpub.value) ?: return
        scanJob = viewModelScope.launch {
            _isScanning.value = true
            try {
                _scannedEvents.value = feedService.scanRelaysForKind3(hex)
            } finally {
                _isScanning.value = false
            }
        }
    }

    fun restoreList(pTags: List<List<String>>, content: String) {
        if (!isViewingActiveAccount) return
        feedService.restoreContactList(pTags, content)
    }

    fun refollow(pubkey: String) {
        if (!isViewingActiveAccount) return
        feedService.followUser(pubkey)
    }

    fun removedSince(snapshot: FollowingSnapshot): List<String> {
        return followingBackupService.removedSince(snapshot, currentFollowedPubkeys)
    }

    fun addedSince(snapshot: FollowingSnapshot): List<String> {
        return followingBackupService.addedSince(snapshot, currentFollowedPubkeys)
    }

    /** People in [list] you no longer follow, in the list's order (iOS removedPubkeys). */
    fun removedSince(list: List<String>): List<String> {
        val current = currentFollowedPubkeys.toSet()
        return list.filter { it !in current }
    }

    /** People you follow now who are not in [list], in your order (iOS addedPubkeys). */
    fun addedSince(list: List<String>): List<String> {
        val old = list.toSet()
        return currentFollowedPubkeys.filter { it !in old }
    }

    fun deleteSnapshot(id: String) {
        followingBackupService.deleteSnapshot(id, _selectedNpub.value)
    }
}

/**
 * One list someone opened: a relay copy ("Contact List Backup") or a local
 * snapshot ("Snapshot Backup"). The same page serves both, as on iOS.
 */
private data class OpenBackup(
    val title: String,
    val source: String,
    val at: Long,
    val pubkeys: List<String>,
    val pTags: List<List<String>>,
    val content: String,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FollowingBackupScreen(
    onBack: () -> Unit,
    viewModel: FollowingBackupViewModel = hiltViewModel(),
) {
    val snapshots by viewModel.snapshots.collectAsState()
    val scannedEvents by viewModel.scannedEvents.collectAsState()
    val isScanning by viewModel.isScanning.collectAsState()
    val selectedNpub by viewModel.selectedNpub.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val followed by viewModel.followedPubkeys.collectAsState()
    val accounts = viewModel.accounts
    // From the collected value, so this scope recomposes on a pick.
    val isActive = viewModel.isActive(selectedNpub)
    /** The list whose page is open; null shows the lists. */
    var open by remember { mutableStateOf<OpenBackup?>(null) }
    LaunchedEffect(Unit) { viewModel.ensureProfiles() }
    LaunchedEffect(selectedNpub) { open = null }

    val opened = open
    if (opened != null) {
        BackHandler { open = null }
        BackupDetailPage(
            backup = opened,
            isActive = isActive,
            followed = followed,
            profiles = profiles,
            viewModel = viewModel,
            onBack = { open = null },
        )
        return
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Following Backup") },
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
        val currentCount = followed.size
        val followedSet = remember(followed) { followed.toSet() }

        LazyColumn(
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 16.dp,
                start = 16.dp,
                end = 16.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            // ── Account picker (iOS: shown with more than one account) ──
            if (accounts.size > 1) {
                item { BackupSectionHeader("Account") }
                items(accounts, key = { "acct-$it" }) { npub ->
                    val isOwner = npub == viewModel.ownerNpub
                    val profile = profiles[HavenBridge.decodeNpub(npub) ?: ""]
                    val name = profile?.bestName ?: if (isOwner) "Owner" else npub.take(12) + "..."
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = SecondaryGroupedBg,
                        modifier = Modifier.fillMaxWidth().clickable { viewModel.selectAccount(npub) },
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp).heightIn(min = 32.dp),
                        ) {
                            AvatarImage(url = profile?.pictureURL, pubkey = HavenBridge.decodeNpub(npub) ?: npub,
                                size = 30.dp, displayName = profile?.bestName)
                            Text(name, color = PrimaryText, fontSize = 15.sp, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                            if (isOwner) {
                                Text("Owner", color = LocalNostrVaultColors.current.primary, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                            }
                            Spacer(Modifier.weight(1f))
                            if (npub == selectedNpub) {
                                Icon(NostrVaultIcons.Check, contentDescription = "Selected",
                                    tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(18.dp))
                            }
                        }
                    }
                }
            }

            // ── Recover Following List (relay copies) ───────────────
            item { BackupSectionHeader("Recover Following List", SettingsHelp.ACCOUNT_FOLLOWING_BACKUP) }

            if (isScanning) {
                item {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = SecondaryText)
                        Spacer(Modifier.width(10.dp))
                        Text("Querying relays…", color = SecondaryText, fontSize = 14.sp)
                    }
                }
            }
            if (scannedEvents.isEmpty() && !isScanning) {
                item {
                    Text(
                        "Tap \"Scan Relays\" to search for historical contact lists.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        modifier = Modifier.padding(vertical = 4.dp),
                    )
                }
            }

            items(scannedEvents, key = { it.id }) { event ->
                BackupListRow(
                    at = event.createdAt * 1000,
                    followCount = event.followCount,
                    trailing = {
                        if (isActive) {
                            if (event.pubkeys.toSet() == followedSet) {
                                DeltaPill("Current", SuccessGreen)
                            } else {
                                FollowingDeltaPill(event.followCount, currentCount)
                            }
                        }
                    },
                ) {
                    open = OpenBackup("Contact List Backup", "backup", event.createdAt * 1000, event.pubkeys, event.pTags, event.content)
                }
            }

            item {
                Button(
                    onClick = { viewModel.scanRelays() },
                    enabled = !isScanning,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(if (scannedEvents.isEmpty()) "Scan Relays" else "Rescan Relays")
                }
            }

            // ── Automatic Backups (local snapshots) ─────────────────
            if (snapshots.isNotEmpty()) {
                item { BackupSectionHeader("Automatic Backups") }
                items(snapshots, key = { it.id }) { snapshot ->
                    BackupListRow(
                        at = snapshot.capturedAt,
                        followCount = snapshot.followCount,
                        trailing = {
                            if (isActive) FollowingDeltaPill(snapshot.followCount, currentCount)
                            IconButton(
                                onClick = { viewModel.deleteSnapshot(snapshot.id) },
                                modifier = Modifier.size(32.dp),
                            ) {
                                Icon(
                                    imageVector = NostrVaultIcons.Delete,
                                    contentDescription = "Delete",
                                    tint = SecondaryText,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        },
                    ) {
                        open = OpenBackup("Snapshot Backup", "snapshot", snapshot.capturedAt, snapshot.pubkeys, snapshot.pTags, snapshot.contactListContent)
                    }
                }
                item {
                    Text(
                        "Snapshots are saved automatically when your following list changes. Up to ${FollowingSnapshotStore.MAX_SNAPSHOTS} are kept.",
                        color = TertiaryText,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }
    }
}

/** The page behind a list row: Summary, Restore, No Longer Following, Added Since (iOS *DetailView). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BackupDetailPage(
    backup: OpenBackup,
    isActive: Boolean,
    followed: List<String>,
    profiles: Map<String, FeedProfile>,
    viewModel: FollowingBackupViewModel,
    onBack: () -> Unit,
) {
    var showRestore by remember { mutableStateOf(false) }
    val followedSet = remember(followed) { followed.toSet() }
    // Who changed, taken once per open, so someone re-followed stays on the
    // list with a checkmark, as on iOS.
    val removed = remember(backup) { if (isActive) viewModel.removedSince(backup.pubkeys) else emptyList() }
    val added = remember(backup) { if (isActive) viewModel.addedSince(backup.pubkeys) else emptyList() }
    LaunchedEffect(removed, added) { viewModel.fetchProfiles(removed + added) }
    val dateFormat = remember { SimpleDateFormat("MMM d, yyyy 'at' h:mm a", Locale.getDefault()) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(backup.title) },
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
        LazyColumn(
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 16.dp,
                start = 16.dp,
                end = 16.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item { BackupSectionHeader("Summary") }
            item {
                Surface(shape = RoundedCornerShape(12.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                        SummaryRow("Date", dateFormat.format(Date(backup.at)))
                        SummaryRow("Following", backup.pubkeys.size.toString())
                        if (isActive) SummaryRow("Current", followed.size.toString())
                    }
                }
            }

            // iOS only offers Restore when it would change something.
            if (isActive && backup.pubkeys.isNotEmpty() && backup.pubkeys.toSet() != followedSet) {
                item {
                    Button(onClick = { showRestore = true }, modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                        Icon(NostrVaultIcons.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Restore This List", fontWeight = FontWeight.SemiBold)
                    }
                }
            }

            if (removed.isNotEmpty()) {
                item { DiffHeader("No Longer Following (${removed.size})") }
                items(removed, key = { "r-$it" }) { pk ->
                    BackupPersonRow(pk, profiles[pk]) {
                        if (pk in followedSet) {
                            Icon(NostrVaultIcons.CheckCircle, contentDescription = "Following", tint = SuccessGreen, modifier = Modifier.size(22.dp))
                        } else {
                            OutlinedButton(
                                onClick = { viewModel.refollow(pk) },
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
                                modifier = Modifier.height(30.dp),
                            ) { Text("Re-follow", fontSize = 12.sp) }
                        }
                    }
                }
                item { DiffFooter("People in this backup that you no longer follow.") }
            }

            if (added.isNotEmpty()) {
                item { DiffHeader("Added Since (${added.size})") }
                items(added, key = { "a-$it" }) { pk ->
                    BackupPersonRow(pk, profiles[pk]) { DeltaPill("New", SuccessGreen) }
                }
                item { DiffFooter("People you follow now that were not in this backup.") }
            }
        }
    }

    if (showRestore) {
        // Same title, message and buttons as iOS.
        AlertDialog(
            onDismissRequest = { showRestore = false },
            title = { Text("Restore Contact List?") },
            text = { Text(restoreMessage(followed.size, backup.pubkeys.size, backup.source)) },
            confirmButton = {
                TextButton(onClick = {
                    showRestore = false
                    viewModel.restoreList(backup.pTags, backup.content)
                }) { Text("Restore", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { showRestore = false }) { Text("Cancel") }
            },
        )
    }
}

/** A list in the lists: date, "time · N following", and the pill (iOS kind3Row / snapshotRow). */
@Composable
private fun BackupListRow(
    at: Long,
    followCount: Int,
    trailing: @Composable RowScope.() -> Unit,
    onClick: () -> Unit,
) {
    val dayFormat = remember { SimpleDateFormat("MMM d, yyyy", Locale.getDefault()) }
    val timeFormat = remember { SimpleDateFormat("h:mm a", Locale.getDefault()) }
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = SecondaryGroupedBg,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(dayFormat.format(Date(at)), color = PrimaryText, fontSize = 15.sp)
                Text(
                    "${timeFormat.format(Date(at))} \u00b7 $followCount following",
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
            }
            trailing()
            Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = TertiaryText, modifier = Modifier.size(16.dp))
        }
    }
}

/**
 * How the live list compares with a backup: "+N" in green when you follow
 * more people now, "-N" in red when fewer, nothing when the same (iOS
 * deltaLabel). Null means no pill.
 */
internal fun followingDeltaLabel(snapshotCount: Int, currentCount: Int): String? {
    val diff = currentCount - snapshotCount
    return when {
        diff > 0 -> "+$diff"
        diff < 0 -> "$diff"
        else -> null
    }
}

@Composable
private fun FollowingDeltaPill(snapshotCount: Int, currentCount: Int) {
    val label = followingDeltaLabel(snapshotCount, currentCount) ?: return
    DeltaPill(label, if (label.startsWith("+")) SuccessGreen else ErrorRed)
}

@Composable
private fun DeltaPill(text: String, color: Color) {
    Text(
        text,
        color = color,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(50))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

@Composable
private fun SummaryRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Text(label, color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Text(value, color = SecondaryText, fontSize = 15.sp)
    }
}

@Composable
private fun BackupSectionHeader(title: String, help: SettingsHelp? = null) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
        Text(title.uppercase(), color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp)
        if (help != null) InfoButton(help)
    }
}

/** A list a Restore button picked; [source] is "backup" (relay) or "snapshot" (local). */
private data class PendingRestore(
    val pTags: List<List<String>>,
    val content: String,
    val followCount: Int,
    val source: String,
)

internal fun restoreMessage(currentCount: Int, restoreCount: Int, source: String): String =
    "This will replace your current $currentCount follows with $restoreCount follows from this $source " +
        "and publish the updated list to your relays."

@Composable
private fun DiffHeader(title: String) {
    Text(
        title.uppercase(),
        color = SecondaryText,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.sp,
        modifier = Modifier.padding(top = 12.dp),
    )
}

@Composable
private fun DiffFooter(text: String) {
    Text(text, color = TertiaryText, fontSize = 12.sp)
}

/** Avatar, name and NIP-05 for one person in a snapshot diff (iOS profileRow). */
@Composable
private fun BackupPersonRow(pubkey: String, profile: FeedProfile?, trailing: @Composable () -> Unit) {
    val name = profile?.bestName ?: (pubkey.take(8) + "..." + pubkey.takeLast(4))
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .background(SecondaryGroupedBg, RoundedCornerShape(10.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 34.dp, displayName = profile?.bestName)
        Column(modifier = Modifier.weight(1f)) {
            Text(name, color = PrimaryText, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            profile?.nip05?.takeIf { it.isNotEmpty() }?.let {
                Text(it, color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        trailing()
    }
}
