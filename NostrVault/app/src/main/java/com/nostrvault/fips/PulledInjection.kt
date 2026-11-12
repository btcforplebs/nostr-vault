package com.nostrvault.fips

/**
 * The second-hand mark (`?pulled=1`) on an address this device writes to another of the owner's devices
 * (the blast list's Mac, HomeVaultSender): that relay stores what arrives and does not blast it again, as
 * this device already did (haven-go isSecondHandConn, device sync map §4.5: only first-hand writes are
 * published). Port of iOS PulledInjection.
 */
object PulledInjection {
    const val NAME = "pulled"

    fun url(relay: String): String {
        val hash = relay.indexOf('#')
        val (head, frag) = if (hash >= 0) relay.substring(0, hash) to relay.substring(hash) else relay to ""
        val q = head.indexOf('?')
        val path = if (q >= 0) head.substring(0, q) else head
        val items = if (q >= 0) head.substring(q + 1).split('&').filter { it.isNotEmpty() && it.substringBefore('=') != NAME } else emptyList()
        return path + "?" + (items + "$NAME=1").joinToString("&") + frag
    }
}
