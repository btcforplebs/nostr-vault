package com.nostrvault.fips

/**
 * One ask for a loopback door to an npub's port 80 (`NvFipsIngress`), with the reason when there is none, so the
 * in-app browser can say which (iOS/Mac: Models/MeshSiteIngress.swift).
 */
sealed interface MeshSiteIngress {
    /** `http://127.0.0.1:<port>/<token>`. Never log it: the path is the token. */
    data class Ready(val base: String) : MeshSiteIngress
    /** The Mesh switch is off. */
    data object MeshOff : MeshSiteIngress
    /** The mesh is on but its engine did not come up. */
    data object EngineOff : MeshSiteIngress
    /** The middle server is set to None: no seeds, so no tree to reach strangers by. */
    data object NoSeeds : MeshSiteIngress
    /** Up, but no tree parent yet (libnvfips -10): no route to anyone. Ask again. */
    data object NotReady : MeshSiteIngress
    /** Anything else: the door did not open. */
    data object Failed : MeshSiteIngress

    /** Worth asking again in a moment: the engine may find its parent. */
    val isWaiting: Boolean get() = this == NotReady

    companion object {
        /** A negative `FipsBridge.ingress` code. [publicSeeds] false turns "no tree yet" into [NoSeeds]: none will come. */
        fun fromCode(rc: Int, publicSeeds: Boolean = true): MeshSiteIngress = when (rc) {
            FipsBridge.ERR_NO_TREE -> if (publicSeeds) NotReady else NoSeeds
            FipsBridge.ERR_NOT_RUNNING -> EngineOff
            else -> Failed
        }
    }
}
