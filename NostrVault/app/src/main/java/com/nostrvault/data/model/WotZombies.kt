package com.nostrvault.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.text.NumberFormat
import java.time.Instant
import java.time.Period
import java.time.ZoneId

/**
 * Zombies in your web: follows who have signed nothing for 90+ days.
 *
 * The vault works this out (haven-go/pkg/wot/zombies.go, read through
 * `WotZombiesC`): any signed event of any kind counts as alive, as Plebs vs.
 * Zombies has it, and the buckets are theirs. This side only decodes, keeps
 * the list to people still followed, and words it. Cleaning up happens on
 * Plebs vs. Zombies ([PLEBS_VS_ZOMBIES_URL]): this app never unfollows anyone
 * for it (Logen 2026-11-01). Port of iOS `WotZombies`.
 */
object WotZombies {
    const val FRESH_DAYS = 90
    const val ROTTING_DAYS = 180
    const val ANCIENT_DAYS = 365
    const val PLEBS_VS_ZOMBIES_URL = "https://plebsvszombies.cc"

    @Serializable
    enum class Bucket(val title: String, val days: Int) {
        @SerialName("fresh") FRESH("Fresh", FRESH_DAYS),
        @SerialName("rotting") ROTTING("Rotting", ROTTING_DAYS),
        @SerialName("ancient") ANCIENT("Ancient", ANCIENT_DAYS);

        val daysText: String get() = "$days+ days"
    }

    @Serializable
    data class Zombie(
        val pubkey: String,
        /** Unix seconds of the newest event found; 0 when none at all. */
        @SerialName("last_seen") val lastSeen: Long = 0,
        val days: Int = 0,
        val bucket: Bucket,
    )

    @Serializable
    data class Report(
        val owner: String,
        val follows: Int = 0,
        val zombies: List<Zombie> = emptyList(),
        @SerialName("checked_at") val checkedAt: Long = 0,
    ) {
        fun count(bucket: Bucket): Int = zombies.count { it.bucket == bucket }

        /**
         * The report as it stands for someone following [following] now:
         * anyone unfollowed since the check (here or in another app) is gone
         * from the list and the counts.
         */
        fun keeping(following: Set<String>): Report {
            val kept = zombies.filter { it.pubkey in following }
            val dropped = zombies.size - kept.size
            return copy(follows = (follows - dropped).coerceAtLeast(0), zombies = kept)
        }
    }

    /** `WotZombiesC`'s answer. */
    @Serializable
    data class State(
        val checking: Boolean = false,
        val report: Report? = null,
        val error: String? = null,
    )

    private val json = Json { ignoreUnknownKeys = true }

    fun parse(raw: String?): State? {
        if (raw.isNullOrBlank()) return null
        return runCatching { json.decodeFromString(State.serializer(), raw) }.getOrNull()
    }

    // Words

    private fun n(value: Int): String = NumberFormat.getIntegerInstance().format(value)

    /** The card's line: "65 of your 1,053 follows have been quiet 90+ days". */
    fun headline(quiet: Int, follows: Int): String {
        if (quiet == 0) return "None of your ${n(follows)} follows have been quiet $FRESH_DAYS+ days"
        val verb = if (quiet == 1) "has" else "have"
        return "${n(quiet)} of your ${n(follows)} follows $verb been quiet $FRESH_DAYS+ days"
    }

    /** The list's header: "65 quiet 90+ days, longest first". */
    fun listHeader(quiet: Int): String = "${n(quiet)} quiet $FRESH_DAYS+ days, longest first"

    /**
     * "Last seen 2 yr 6 mo ago", "Last seen 11 months ago", or that nothing
     * signed by them was found at all.
     */
    fun lastSeenText(lastSeen: Long, nowSeconds: Long = System.currentTimeMillis() / 1000, zone: ZoneId = ZoneId.systemDefault()): String {
        if (lastSeen <= 0) return "Nothing signed by them found"
        val then = Instant.ofEpochSecond(lastSeen).atZone(zone).toLocalDate()
        val now = Instant.ofEpochSecond(nowSeconds).atZone(zone).toLocalDate()
        val p = if (then.isAfter(now)) Period.ZERO else Period.between(then, now)
        val years = p.years
        val months = p.months
        if (years > 0) return if (months > 0) "Last seen $years yr $months mo ago" else "Last seen $years yr ago"
        if (months > 0) return "Last seen $months ${if (months == 1) "month" else "months"} ago"
        val days = p.days
        return "Last seen $days ${if (days == 1) "day" else "days"} ago"
    }
}
