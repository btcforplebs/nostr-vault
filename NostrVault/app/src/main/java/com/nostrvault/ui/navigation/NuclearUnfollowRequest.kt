package com.nostrvault.ui.navigation

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The person a profile's ··· › Nuclear unfollow was asked for. It opens the
 * WOT tab on them, whose card lights them and your follows who follow them,
 * with Show list over the globe (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md).
 */
object NuclearUnfollowRequest {
    private val _target = MutableStateFlow<String?>(null)
    val target: StateFlow<String?> = _target

    fun start(pubkey: String) {
        _target.value = pubkey
        WotOpenRequest.open(pubkey)
    }

    fun clear() { _target.value = null }
}
