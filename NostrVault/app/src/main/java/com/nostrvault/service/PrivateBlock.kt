package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore

/**
 * Blocks [npub] privately for the active account: in the mute list's encrypted
 * part and out of its public "p" tags, so nobody else can see it. Nothing is
 * stored here first; the block shows once the published list is read back
 * ([NostrService.applyMuteList]), and from then on keeps them out of your web
 * (feeds, notifications, the WoT gate and globe). Returns what to tell the
 * person, or null. Settings › Blocked and a profile's ··· menu both use it.
 * iOS: ConfigService.blockPrivately.
 */
suspend fun NostrService.blockPrivately(configStore: ConfigStore, npub: String): String? {
    val cfg = configStore.config.value
    val key = cfg.activeOrOwnerNpub()
    if (npub in cfg.privateBlockedNpubsPerAccount[key].orEmpty()) return null
    return publishMuteListChange(
        key, add = listOf(npub), localBlocks = cfg.publicBlockedFor(key).filter { it != npub }, privately = true,
    )
}
