package com.nostrvault.ui.navigation

import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Hands a destination from the Activity, which receives the intent, to the nav
 * host, which is the only thing that can act on it.
 *
 * A plain object rather than a ViewModel because an intent can arrive before
 * the composition exists (cold start from a notification tap): the target sits
 * here until the nav host collects it, and [consume] clears it so a
 * configuration change does not replay the navigation.
 */
object PendingDeepLink {
    private val _target = MutableStateFlow<DeepLinkTarget?>(null)
    val target: StateFlow<DeepLinkTarget?> = _target

    fun post(target: DeepLinkTarget) { _target.value = target }

    fun consume(): DeepLinkTarget? = _target.value?.also { _target.value = null }
}

/** [NostrEntityDecoder] backed by the app's own bech32 implementation. */
object BridgeEntityDecoder : NostrEntityDecoder {
    override fun noteToHex(note1: String): String? = HavenBridge.decodeNote(note1)
    override fun neventToHex(nevent1: String): String? = HavenBridge.decodeNevent(nevent1)
    override fun npubToHex(npub: String): String? = HavenBridge.decodeNpub(npub)
    override fun nprofileToHex(nprofile: String): String? = HavenBridge.decodeNprofilePubkey(nprofile)
}
