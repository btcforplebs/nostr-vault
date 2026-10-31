package com.nostrvault.ui.screens

import androidx.compose.runtime.Stable
import com.nostrvault.service.BlossomBackupSummary

/**
 * A grid tile's or list row's Blossom backup answer and the actions on it.
 * The tiles no longer ask the servers (that was a GET per server per tile),
 * so [summary] is only known once the photo screen or an action has asked.
 */
@Stable
internal class BackupBadgeState(
    /** Null until every configured server has answered once. */
    val summary: BlossomBackupSummary?,
    val mirrorCount: Int,
    /** The file is on this phone, so it can be uploaded. */
    val isLocal: Boolean,
    val busy: Boolean,
    val onMirror: () -> Unit,
    val onSaveToVault: () -> Unit,
) {
    /**
     * The menu's Mirror to Blossom: also offered while no server has been
     * asked yet, since the upload asks the servers first. iOS `mayNeedMirror`.
     */
    val mayNeedMirror: Boolean get() = mayNeedMirror(isLocal, mirrorCount, summary)

    companion object {
        fun mayNeedMirror(isLocal: Boolean, mirrorCount: Int, summary: BlossomBackupSummary?): Boolean =
            isLocal && mirrorCount > 0 && (summary?.needsMirror ?: true)
    }
}
