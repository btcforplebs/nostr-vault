package com.nostrvault.relay

/**
 * The desktop Vault status read over the mesh (VaultStatusFromC, haven-go/copyv2_status_client.go): kept out of
 * [HavenBridge], which is over 800 lines. Same native library; [HavenBridge] loads it.
 */
object VaultStatusBridge {
    /**
     * {"status": {...}} or {"error": "<code>"} from [peer] (its mesh npub) through [base], with the copy token. Blocks
     * up to 15 s: call it off the main thread. Null when the library isn't loaded.
     */
    fun read(peer: String, base: String): String? =
        if (HavenBridge.isLoaded) runCatching { statusFrom(peer, base) }.getOrNull() else null

    private external fun statusFrom(peer: String, base: String): String?
}
