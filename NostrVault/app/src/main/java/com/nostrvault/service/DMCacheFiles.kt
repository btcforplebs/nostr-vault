package com.nostrvault.service

/** Cache file names, kept apart so the old-format rule is unit-tested. */
internal object DMCacheFiles {
    /**
     * A DM cache not keyed on a full 64-hex pubkey: written before the key was
     * the account's hex ("npub1xxxxxxx", 12 hex characters, "default").
     */
    fun isOldKeyCache(name: String): Boolean {
        if (!name.startsWith("dm_cache_") || !name.endsWith(".json")) return false
        val key = name.removePrefix("dm_cache_").removeSuffix(".json")
        return !(key.length == 64 && key.all { it in '0'..'9' || it in 'a'..'f' })
    }
}
