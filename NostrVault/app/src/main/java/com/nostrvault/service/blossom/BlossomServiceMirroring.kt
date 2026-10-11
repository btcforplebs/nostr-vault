package com.nostrvault.service

import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import com.nostrvault.service.BlossomService.MirrorPushResult

    /**
     * Uploads a blob already on this phone to the servers not known to have
     * it, then re-checks so badges show the new count. Null when every server
     * already had it. Port of iOS `MediaBackupActions.mirrorMissing`.
     */
    suspend fun BlossomService.pushToMissing(sha256: String): MirrorPushResult? {
        checkMirrorPresence(sha256, force = true)
        val summary = backupSummary(sha256)
        if (summary != null && !summary.needsMirror) return null
        val result = pushLocalToMirrors(sha256, only = summary?.missing)
        checkMirrorPresence(sha256, force = true)
        return result
    }
