package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.nostrvault.service.BlossomBackupSummary
import com.nostrvault.ui.screens.BackupBadgeState
import com.nostrvault.ui.screens.BlossomBackupBadge

/** When a profile media tile shows its backup badge. iOS MediaGridItem's bottom-trailing overlay. */
internal object ProfileTileBackup {
    /**
     * The blob hash to count, or null for no badge: only a Blossom file (named
     * by its hash) can be looked up, and only once you have a Blossom server.
     * On anyone's profile, as iOS: it says whether *your* servers hold it.
     */
    fun badgeHash(url: String, mirrors: List<String>): String? =
        if (mirrors.isEmpty()) null else blossomHashOf(url)
}

/**
 * The compact cloud "x/y" badge in a media tile's bottom-trailing corner: how
 * many of your Blossom servers hold the file, so what is not backed up shows
 * without opening it. Asks the servers once per file; nothing for a file
 * that is not on Blossom or when you have no server.
 */
@Composable
internal fun ProfileTileBackupBadge(url: String, modifier: Modifier = Modifier) {
    val services = rememberProfileContentServices()
    val config by services.configStore().config.collectAsState()
    val mirrors = config.activeBlossomMirrors
    val hash = remember(url, mirrors) { ProfileTileBackup.badgeHash(url, mirrors) } ?: return
    val blossom = services.blossomService()
    val presence by blossom.mirrorPresence.collectAsState()
    val summary = BlossomBackupSummary.of(presence[hash], mirrors)
    BlossomBackupBadge(
        backup = BackupBadgeState(
            summary = summary,
            mirrorCount = mirrors.size,
            mirrorsKey = mirrors,
            busy = false,
            check = { blossom.checkMirrorPresence(hash) },
            // The tile's own long-press menu mirrors and saves; the badge only counts.
            onMirror = {},
            onSaveToVault = {},
        ),
        compact = true,
        modifier = modifier
            .padding(4.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
}
