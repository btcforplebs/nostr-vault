package com.nostrvault.relay

/**
 * The relay to name in a reply's `e`/`E` hint. It used to be [HavenConfig.nostrURL],
 * the phone's own `ws://127.0.0.1` relay unless an external relay was set, so other
 * clients were pointed at themselves and the thread broke apart for them
 * (2026-11-26). Now: an external relay others can reach, else the first reachable
 * `wss://` write relay. Desktop Vaults are skipped (they may not serve strangers).
 * "" when nothing public is left. The iOS twin is `HavenConfig.replyRelayHint`.
 */
object ReplyRelayHint {
    fun pick(config: HavenConfig): String = pick(
        own = config.nostrURL.takeIf { config.useExternalRelay },
        writeRelays = config.blastrRelays.ifEmpty { RelayConfiguration.FALLBACK_WRITE_RELAYS },
    )

    fun pick(own: String?, writeRelays: List<String>): String {
        own?.let(::reachable)?.let { return it }
        return writeRelays.firstNotNullOfOrNull(::reachable) ?: ""
    }

    private fun reachable(raw: String): String? {
        val url = raw.trim()
        if (!url.lowercase().startsWith("wss://")) return null
        val hostPort = url.substring("wss://".length)
        return url.takeIf { hostPort.isNotEmpty() && !DMInbox.isPrivateNetworkHost(hostPort) }
    }
}
