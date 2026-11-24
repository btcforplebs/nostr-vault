package com.nostrvault.relay

import com.nostrvault.ui.screens.settings.RelayAccessLimits
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * One account's own "Who Can Reach You": its Follow Distance level (1 only
 * you, 2 the people you follow, 3 the people they follow too) and the
 * Minimum Followers bar of level 3. The relay builds each account's web from
 * that account's own follows at this level (haven-go account_reach.go).
 * Twin of Apple AccountReach.swift.
 */
@kotlinx.serialization.Serializable
data class AccountReach(val depth: Int, val minFollowers: Int) {
    /** Held to what the screen offers and the relay runs. */
    val clamped: AccountReach
        get() = AccountReach(RelayAccessLimits.clampedFollowDistance(depth), minFollowers.coerceIn(MIN_FOLLOWERS))

    companion object {
        val MIN_FOLLOWERS = 0..100

        /** The file the relay reads each account's reach from (ACCOUNT_REACH_FILE). */
        const val FILE_NAME = "account_reach.json"

        /** The file's text: `{"v":1,"accounts":{"npub1…":{"depth":2,"min_followers":3}}}`, npubs sorted. */
        fun fileJson(reach: Map<String, AccountReach>): String = buildJsonObject {
            put("v", 1)
            putJsonObject("accounts") {
                for ((npub, r) in reach.toSortedMap()) {
                    put(npub, JsonObject(mapOf("depth" to JsonPrimitive(r.depth), "min_followers" to JsonPrimitive(r.minFollowers))))
                }
            }
        }.toString()
    }
}

/*
 * Follow Distance per account (Logen 2026-11-22: "Follow Distance has to be
 * per account, so we don't mash mute lists together"). Twin of Apple
 * HavenConfig+AccountReach.swift.
 *
 * - The first account's value is the pair this config always had
 *   (chatRelayWotDepth, chatRelayMinFollowers). It still goes to the relay as
 *   WOT_DEPTH / WOT_MINIMUM_FOLLOWERS and to your other devices as the mesh's
 *   wot_depth, so older builds keep working with it.
 * - Every other account's value is its entry in reachPerAccount, handed to
 *   the relay in account_reach.json. An account with no entry yet uses the
 *   first account's value, which is what every account ran on before.
 *
 * Changing the first account's value first gives every other account its own
 * entry at the old value, so one account's change never moves another.
 */

/** The account the app is showing: the first account when none is picked. */
val HavenConfig.reachAccountNpub: String
    get() = activeOrOwnerNpub().trim()

private val HavenConfig.firstAccountReach: AccountReach
    get() = AccountReach(chatRelayWotDepth, chatRelayMinFollowers).clamped

private fun HavenConfig.isFirstAccount(npub: String): Boolean = npub.isEmpty() || npub == ownerNpub.trim()

/** Every account besides the first one, watch-only included. */
private val HavenConfig.otherAccountNpubs: List<String>
    get() = accountNpubs.map { it.trim() }.filter { it.isNotEmpty() && !isFirstAccount(it) }.distinct()

/** [raw]'s own reach. */
fun HavenConfig.reachFor(raw: String): AccountReach {
    val npub = raw.trim()
    if (isFirstAccount(npub)) return firstAccountReach
    return reachPerAccount[npub]?.clamped ?: firstAccountReach
}

/** This config with [raw]'s own reach set to [reach], and nobody else's changed. */
fun HavenConfig.withReach(reach: AccountReach, raw: String): HavenConfig {
    val npub = raw.trim()
    val value = reach.clamped
    if (!isFirstAccount(npub)) return copy(reachPerAccount = reachPerAccount + (npub to value))
    if (value == firstAccountReach) return this
    return keepingOtherAccountsReach().copy(chatRelayWotDepth = value.depth, chatRelayMinFollowers = value.minFollowers)
}

/**
 * Gives every other account that has no entry yet its own, at the value it
 * runs on now. Call before the first account's value changes.
 */
fun HavenConfig.keepingOtherAccountsReach(): HavenConfig {
    val current = firstAccountReach
    val missing = otherAccountNpubs.filter { it !in reachPerAccount }
    if (missing.isEmpty()) return this
    return copy(reachPerAccount = reachPerAccount + missing.associateWith { current })
}

/**
 * What account_reach.json holds: the entry of every other account still on
 * this device. The first account is left out (it is the relay's WOT_DEPTH),
 * and so is a removed account.
 */
val HavenConfig.relayAccountReach: Map<String, AccountReach>
    get() = otherAccountNpubs.mapNotNull { npub -> reachPerAccount[npub]?.let { npub to it.clamped } }.toMap()
