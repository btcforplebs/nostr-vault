package com.nostrvault.fips

/**
 * A's side of a pairing (it shows its code first): takes hellos and B's code, and says what to do. Pure: the caller
 * has already checked the hello event's signature and decrypted it with the mesh key. Same as iOS
 * MeshPairingSession.swift; docs/MESH_PAIRING_CONTRACT.md §4.
 */
class MeshPairingSession(
    val secret: String,
    val createdAt: Long,
    val ownMeshHex: String,
    val active: String?,
    val accounts: List<String>,
) {
    sealed interface Outcome {
        /** The hello is good: open the camera on B. */
        data class Camera(val hello: MeshPairing.Hello) : Outcome
        data object IgnoreDuplicate : Outcome
        /** Two hellos for one code (Tron 3): stop, nothing is stored. */
        data object Abort : Outcome
        data object Expired : Outcome
        /** Not for this session; keep waiting quietly. */
        data class Ignore(val why: String) : Outcome
        data class Refuse(val why: String) : Outcome
        /** B is confirmed: show the role confirm, then store it. */
        data class Confirm(val npub: String, val name: String, val role: DeviceRole) : Outcome
        data class Reject(val why: String) : Outcome
        /** B's code didn't read; say why with [MeshPairing.text]. */
        data class Unreadable(val refusal: MeshPairing.Refusal) : Outcome
    }

    enum class State { Waiting, Camera, Done, Expired, Aborted }

    var state = State.Waiting
        private set
    var senderHex: String? = null
        private set
    var hello: MeshPairing.Hello? = null
        private set
    private var helloAt = 0L

    fun receiveHello(sender: String, content: String, now: Long): Outcome {
        when (state) {
            State.Done, State.Expired -> return Outcome.Expired
            State.Aborted -> return Outcome.Abort
            else -> Unit
        }
        val h = MeshPairing.parseHello(content) ?: return Outcome.Ignore("notHello")
        if (sender == ownMeshHex) return Outcome.Ignore("ownAddress")
        if (h.secret != secret) return Outcome.Ignore("wrongSecret")
        if (kotlin.math.abs(now - h.time) > MeshPairing.HELLO_SKEW) return Outcome.Ignore("stale")
        when (MeshPairing.ownerCheck(h.owner, active, accounts)) {
            MeshPairing.OwnerCheck.Ok -> Unit
            is MeshPairing.OwnerCheck.SwitchTo -> return Outcome.Refuse("switchTo")
            MeshPairing.OwnerCheck.OtherOwner -> return Outcome.Refuse("otherOwner")
        }
        if (state == State.Waiting) {
            if (now - createdAt > MeshPairing.CODE_LIFETIME) {
                state = State.Expired
                return Outcome.Expired
            }
            state = State.Camera
            senderHex = sender
            hello = h
            helloAt = now
            return Outcome.Camera(h)
        }
        if (sender == senderHex && h == hello) return Outcome.IgnoreDuplicate
        state = State.Aborted
        return Outcome.Abort
    }

    /** B's code, scanned by A's camera. */
    fun acceptSecondQR(uri: String, now: Long): Outcome {
        guardScan(now)?.let { return it }
        val payload = when (val p = MeshPairing.parse(uri, MeshPairing.npub(ownMeshHex))) {
            is MeshPairing.Parsed.Refused -> return Outcome.Unreadable(p.refusal)
            is MeshPairing.Parsed.Ok -> p.payload
        }
        val echo = payload.code as? MeshPairing.Code.Echo ?: return Outcome.Reject("notTheirCode")
        if (echo.value != secret) return Outcome.Reject("echoMismatch")
        if (payload.meshHex != senderHex || payload.role != hello?.role) return Outcome.Reject("notTheDevice")
        return finish()
    }

    /** Accept with the check words, on a device that can't scan (§4). */
    fun acceptWithoutScan(now: Long): Outcome {
        guardScan(now)?.let { return it }
        return finish()
    }

    private fun guardScan(now: Long): Outcome? = when (state) {
        State.Aborted -> Outcome.Abort
        State.Done, State.Expired -> Outcome.Expired
        State.Waiting -> Outcome.Reject("notReady")
        State.Camera -> if (now - helloAt > MeshPairing.SCAN_WINDOW) {
            state = State.Expired
            Outcome.Expired
        } else {
            null
        }
    }

    private fun finish(): Outcome {
        state = State.Done
        val sender = senderHex ?: return Outcome.Reject("notReady")
        val h = hello ?: return Outcome.Reject("notReady")
        return Outcome.Confirm(MeshPairing.npub(sender), h.name, h.role)
    }
}

/** B's side (it scanned A): waits for A's ack, and on the Accept path for this side's own "They match" tap (Tron 2). */
class MeshPairingJoiner private constructor(
    val a: MeshPairing.Payload,
    val ownMeshHex: String,
    val scannedAt: Long,
    private val expected: String?,
) {
    sealed interface Outcome {
        data object Linked : Outcome
        data object WaitWords : Outcome
        data object WaitAck : Outcome
        data object IgnoreDuplicate : Outcome
        data object Expired : Outcome
        data class Ignore(val why: String) : Outcome
    }

    enum class State { Waiting, WaitWords, Linked, Expired }

    var state = State.Waiting
        private set
    private var wordsConfirmed = false

    fun receiveAck(sender: String, content: String, now: Long): Outcome {
        when (state) {
            State.Linked -> return Outcome.IgnoreDuplicate
            State.Expired -> return Outcome.Expired
            else -> Unit
        }
        val ack = MeshPairing.parseAck(content) ?: return Outcome.Ignore("notAck")
        if (sender != a.meshHex) return Outcome.Ignore("wrongSender")
        if (ack.digest != expected) return Outcome.Ignore("badDigest")
        if (now - scannedAt > MeshPairing.ACK_WINDOW) {
            state = State.Expired
            return Outcome.Expired
        }
        if (ack.words && !wordsConfirmed) {
            state = State.WaitWords
            return Outcome.WaitWords
        }
        state = State.Linked
        return Outcome.Linked
    }

    fun confirmWords(): Outcome = when (state) {
        State.Linked -> Outcome.IgnoreDuplicate
        State.Expired -> Outcome.Expired
        State.WaitWords -> {
            state = State.Linked
            Outcome.Linked
        }
        State.Waiting -> {
            wordsConfirmed = true
            Outcome.WaitAck
        }
    }

    companion object {
        /** Null unless [qrA] is A's code (a secret, not an echo). */
        fun start(qrA: MeshPairing.Payload, ownMeshHex: String, scannedAt: Long): MeshPairingJoiner? {
            val s = qrA.code as? MeshPairing.Code.Secret ?: return null
            return MeshPairingJoiner(qrA, ownMeshHex, scannedAt, MeshPairing.ackDigest(s.value, qrA.meshHex, ownMeshHex))
        }
    }
}
