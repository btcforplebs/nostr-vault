package com.nostrvault.fips

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * What strangers may pull from this phone's mesh door in one day, all sharing sessions together (iOS
 * KioskDailyBudget, ported whole). It replaces the "Pause after" picker (iPhone #1023): My Devices are not
 * counted and never wait; strangers get [DAILY] a day, and at the limit they wait until tomorrow while sharing
 * stays on, so someone who uses up the limit with throwaway mesh keys cannot turn this vault's sharing off.
 *
 * The engine caps one session; each session gets only what is left of today ([sessionLimit]). Pure for the tests:
 * every time and zone is passed in.
 */
@Serializable
data class KioskDailyBudget(
    /** Local day, `yyyy-MM-dd`. */
    val day: String = "",
    @SerialName("used_bytes") val usedBytes: Long = 0,
    /** The engine's strangers `tx` at the last poll; null until the first poll of a newly started engine. */
    @SerialName("last_engine_tx") val lastEngineTx: Long? = null,
) {
    val remaining: Long get() = (DAILY - usedBytes).coerceAtLeast(0)
    val spent: Boolean get() = remaining == 0L

    /** The limit sent to the engine for a new session. Never 0: the engine reads 0 as its 1 GB default. */
    val sessionLimit: Long get() = remaining.coerceAtLeast(1)

    /** A new day starts from nothing used. */
    fun roll(nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): KioskDailyBudget {
        val today = dayKey(nowMs, zone)
        return if (day == today) this else copy(day = today, usedBytes = 0)
    }

    /** A new engine counts from zero. */
    fun engineStarted(): KioskDailyBudget = copy(lastEngineTx = null)

    /**
     * The engine reported its session limit. Returns the budget and when strangers may be served again (ms). A
     * session started today was given what was left of today, so today is spent (the poll may not have counted the
     * last bytes yet) and they wait until tomorrow. A session started on an earlier day ran out on yesterday's
     * numbers: share again now.
     */
    fun capReached(sessionDay: String, nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): Pair<KioskDailyBudget, Long> {
        val rolled = roll(nowMs, zone)
        if (sessionDay != rolled.day) return rolled to nowMs
        return rolled.copy(usedBytes = DAILY) to nextDay(nowMs, zone)
    }

    /**
     * Adds what the engine sent to strangers since the last poll. A count lower than the last one means the engine
     * started counting again (a new session), so all of it is new.
     */
    fun record(engineTx: Long, nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): KioskDailyBudget {
        val rolled = roll(nowMs, zone)
        val last = rolled.lastEngineTx
        val delta = if (last != null && engineTx >= last) engineTx - last else engineTx
        return rolled.copy(lastEngineTx = engineTx, usedBytes = (rolled.usedBytes + delta.coerceAtLeast(0)).coerceAtMost(DAILY))
    }

    companion object {
        /** iOS MeshDevicesLogic.kioskStrangersTotal. */
        const val DAILY: Long = 1L shl 30

        fun dayKey(nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): String =
            Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate().toString()

        /** The start of the day after [nowMs] (ms): when a spent budget fills again. */
        fun nextDay(nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): Long {
            val today: LocalDate = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
            return today.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        }

        /** What the manager does on a poll (iOS KioskCapPause.step). */
        fun step(capReached: Boolean, pausedUntilMs: Long?, nowMs: Long): Step = when {
            pausedUntilMs == null -> if (capReached) Step.PAUSE else Step.NONE
            nowMs >= pausedUntilMs -> Step.RESUME
            else -> Step.NONE
        }
    }

    enum class Step {
        NONE,
        /** The engine reported the limit: stay on, share again at the time [capReached] gives. */
        PAUSE,
        /** The pause is over: start a new sharing session. */
        RESUME,
    }
}
