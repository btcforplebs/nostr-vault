package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.theme.*

/**
 * User profile screen with header, stats, section tabs, and note list.
 * Port of ProfileView.swift.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileScreen(
    pubkey: String,
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onEditProfile: () -> Unit,
    onNavigateToDMs: () -> Unit = {},
    onNavigateToSettings: () -> Unit = {},
    onBack: () -> Unit,
    viewModel: ProfileViewModel = hiltViewModel(),
) {
    // Initialize ViewModel with the pubkey parameter
    LaunchedEffect(pubkey) {
        if (viewModel.pubkey.isEmpty() || viewModel.pubkey != pubkey) {
            viewModel.setPubkey(pubkey)
        }
    }

    val profile by viewModel.profile.collectAsState()
    val filteredNotes by viewModel.filteredNotes.collectAsState()
    val selectedSection by viewModel.selectedSection.collectAsState()
    val isFollowing by viewModel.isFollowing.collectAsState()
    val isOwnProfile by viewModel.isOwnProfile.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val followersCount by viewModel.followersCount.collectAsState()
    val followingCount by viewModel.followingCount.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()

    // Fetch embedded quoted notes (nostr:note1.../nevent1...) for visible notes
    // plus their authors' profiles, so they resolve instead of spinning forever.
    LaunchedEffect(filteredNotes) {
        val quotedIds = filteredNotes.flatMap { it.quotedEventIds }.distinct()
        if (quotedIds.isNotEmpty()) viewModel.fetchMissingQuotedNotes(quotedIds)
    }
    LaunchedEffect(filteredNotes, quotedNotesCache) {
        val quotedIds = filteredNotes.flatMap { it.quotedEventIds }.distinct()
        if (quotedIds.isNotEmpty()) viewModel.fetchMissingQuotedProfiles(quotedIds)
    }
    val colors = LocalNostrVaultColors.current

    GlassScaffold(
        toolbar = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                // Leading pill: wallet buttons (own profile) or back (other profile)
                GlassPill {
                    if (isOwnProfile) {
                        // Lightning wallet
                        IconButton(onClick = { /* lightning wallet */ }, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Zap, "Lightning", tint = colors.primary, modifier = Modifier.size(25.dp))
                        }
                        // Ecash wallet
                        IconButton(onClick = { /* ecash wallet */ }, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.EcashWallet, "Ecash", tint = colors.primary, modifier = Modifier.size(25.dp))
                        }
                    } else {
                        IconButton(onClick = onBack, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Back, "Back", tint = PrimaryText, modifier = Modifier.size(25.dp))
                        }
                    }
                }

                Spacer(Modifier.weight(1f))

                // Trailing pill: DMs + Settings (own) or Message (other)
                GlassPill {
                    if (isOwnProfile) {
                        // DMs
                        IconButton(onClick = onNavigateToDMs, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.DMs, "Messages", tint = PrimaryText, modifier = Modifier.size(25.dp))
                        }
                        // Settings
                        IconButton(onClick = onNavigateToSettings, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Settings, "Settings", tint = PrimaryText, modifier = Modifier.size(25.dp))
                        }
                    } else {
                        IconButton(onClick = { /* DM */ }, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Chat, "Message", tint = SecondaryText, modifier = Modifier.size(25.dp))
                        }
                    }
                }
            }
        },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 88.dp,
            ),
            modifier = Modifier.fillMaxSize(),
        ) {
            // Profile header
            item {
                ProfileHeader(
                    profile = profile,
                    isOwnProfile = isOwnProfile,
                    isFollowing = isFollowing,
                    followersCount = followersCount,
                    followingCount = followingCount,
                    notesCount = filteredNotes.size,
                    onFollow = viewModel::toggleFollow,
                    onEditProfile = onEditProfile,
                )
            }

            // Section tabs
            item {
                ProfileSectionTabs(
                    selected = selectedSection,
                    onSelect = viewModel::setSection,
                )
            }

            // Notes list
            if (isLoading) {
                item {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(32.dp),
                    ) {
                        CircularProgressIndicator(
                            color = colors.primary,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                }
            } else if (filteredNotes.isEmpty()) {
                item {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(32.dp),
                    ) {
                        Text(
                            text = "No ${selectedSection.displayName.lowercase()} yet",
                            color = SecondaryText,
                            fontSize = 15.sp,
                        )
                    }
                }
            } else {
                items(
                    items = filteredNotes,
                    key = { it.id },
                ) { note ->
                    val quotedNotesMap = remember(note.id, note.quotedEventIds, quotedNotesCache) {
                        note.quotedEventIds.mapNotNull { qid ->
                            viewModel.quotedNoteFor(qid)?.let { qid to it }
                        }.toMap()
                    }
                    NoteCard(
                        note = note,
                        profile = viewModel.profileFor(note.pubkey),
                        stats = viewModel.statsFor(note.id),
                        profiles = profiles,
                        quotedNotes = quotedNotesMap,
                        isLiked = viewModel.isLiked(note.id),
                        onNoteClick = onNoteClick,
                        onProfileClick = onProfileClick,
                        onLike = viewModel::likeNote,
                        onRepost = viewModel::repostNote,
                    )
                    HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                }
            }
        }
    }
}

@Composable
private fun ProfileHeader(
    profile: com.nostrvault.data.model.FeedProfile?,
    isOwnProfile: Boolean,
    isFollowing: Boolean,
    followersCount: Int,
    followingCount: Int,
    notesCount: Int,
    onFollow: () -> Unit,
    onEditProfile: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 16.dp),
    ) {
        // Avatar
        AvatarImage(
            url = profile?.pictureURL,
            pubkey = profile?.pubkey ?: "",
            size = 80.dp,
            displayName = profile?.bestName,
        )

        Spacer(Modifier.height(12.dp))

        // Name
        Text(
            text = profile?.bestName ?: "Unknown",
            color = PrimaryText,
            fontSize = 22.sp,
            fontWeight = FontWeight.Bold,
        )

        // NIP-05
        profile?.nip05?.let { nip05 ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = NostrVaultIcons.Verified,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    text = nip05,
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
            }
        }

        // Bio
        profile?.about?.takeIf { it.isNotBlank() }?.let { bio ->
            Spacer(Modifier.height(8.dp))
            Text(
                text = bio,
                color = SecondaryText,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }

        Spacer(Modifier.height(16.dp))

        // Stats row
        Row(
            horizontalArrangement = Arrangement.SpaceEvenly,
            modifier = Modifier.fillMaxWidth(),
        ) {
            ProfileStat(value = notesCount, label = "Notes")
            ProfileStat(value = followingCount, label = "Following")
            ProfileStat(value = followersCount, label = "Followers")
        }

        Spacer(Modifier.height(16.dp))

        // Action button
        if (isOwnProfile) {
            Button(
                onClick = onEditProfile,
                colors = ButtonDefaults.buttonColors(
                    containerColor = colors.primary,
                ),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth(0.6f),
            ) {
                Text(
                    text = "Edit Profile",
                    fontWeight = FontWeight.SemiBold,
                )
            }
        } else {
            Button(
                onClick = onFollow,
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (isFollowing) SecondaryGroupedBg else colors.primary,
                ),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth(0.6f),
            ) {
                Text(
                    text = if (isFollowing) "Unfollow" else "Follow",
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun ProfileStat(value: Int, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = value.toString(),
            color = PrimaryText,
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(
            text = label,
            color = SecondaryText,
            fontSize = 12.sp,
        )
    }
}

@Composable
private fun ProfileSectionTabs(
    selected: ProfileSection,
    onSelect: (ProfileSection) -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    TabRow(
        selectedTabIndex = ProfileSection.entries.indexOf(selected),
        containerColor = WindowBackground,
        contentColor = colors.primary,
        divider = { HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp) },
    ) {
        ProfileSection.entries.forEach { section ->
            Tab(
                selected = section == selected,
                onClick = { onSelect(section) },
                text = {
                    Text(
                        text = section.displayName,
                        fontWeight = if (section == selected) FontWeight.SemiBold else FontWeight.Normal,
                    )
                },
                selectedContentColor = colors.primary,
                unselectedContentColor = SecondaryText,
            )
        }
    }
}
