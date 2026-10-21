package com.nostrvault.relay

/** Config-level joined group (no dependency on service layer). */
@kotlinx.serialization.Serializable
data class JoinedGroupConfig(
    val relayURL: String,
    val groupId: String,
    val displayName: String? = null,
)
