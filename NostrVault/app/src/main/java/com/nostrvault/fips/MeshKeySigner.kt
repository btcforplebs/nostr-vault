package com.nostrvault.fips

import android.util.Base64
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.EventPublisher
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive

/**
 * Signs with this device's own mesh key (the engine's, made by [FipsMeshManager]), never the owner's: the copy start
 * and Blossom over the mesh ([MeshKeyAuth]). With [MeshPairingHello] (kind 21195) the only readers of the mesh nsec
 * outside the engine (Tron T2): read per call, never logged, never kept, and only the kinds in [KINDS] are signed, so
 * this is no general signing function. A missing key is the engine's to make, so nothing is signed. Twin of Apple's
 * `MeshKeySigner.swift` (#1803).
 */
object MeshKeySigner {
    /** The copy start (27235) and Blossom over the mesh (24242): nothing else is signed here. */
    val KINDS = setOf(MeshKeyAuth.START_KIND, MeshKeyAuth.BLOSSOM_KIND)

    /** Swapped in the tests: the mesh nsec, or null when the engine has not made one. */
    internal var readNsec: () -> String? = { runCatching { CredentialStore.readMeshNsec() }.getOrNull() }

    /**
     * A signed event as the base64 an `Authorization: Nostr` header carries (the engine adds "Nostr " for the start),
     * or null when this device has no mesh key, [kind] is not one this signs, or signing failed.
     */
    fun authorization(kind: Int, content: String, tags: List<List<String>>): String? {
        if (kind !in KINDS) return null
        val signed = withKey { sec, pub ->
            val unsigned = EventPublisher.buildUnsignedEvent(pub, kind, content, tags)
            EventPublisher.signWithGoBackend(unsigned, sec)?.takeIf { signedBy(it, pub, kind) }
        } ?: return null
        return Base64.encodeToString(signed.toByteArray(), Base64.NO_WRAP)
    }

    /**
     * A Blossom token over the mesh for [receivers] ([MeshKeyAuth.blossomTags]), or null with no mesh key. [content]
     * gets a random word: a vault takes each token id once, so two for the same blob signed in the same second must
     * differ.
     */
    fun blossom(
        verb: MeshKeyAuth.Verb,
        sha256s: List<String>,
        receivers: List<String>,
        content: String,
        lifetimeS: Long = MeshKeyAuth.BLOSSOM_LIFETIME_S,
        size: Long? = null,
    ): String? {
        val tags = MeshKeyAuth.blossomTags(verb, sha256s, receivers, lifetimeS = lifetimeS, size = size) ?: return null
        return authorization(MeshKeyAuth.BLOSSOM_KIND, "$content ${java.util.UUID.randomUUID().toString().take(8)}", tags)
    }

    /** This device's mesh npub from its key, read only: null when the engine has not made one yet (never makes one). */
    fun npub(): String? = withKey { _, pub -> HavenBridge.encodeNpub(pub) }

    /** The mesh key for one call: read, used, dropped. Never logged (Tron T2). */
    internal fun <T> withKey(block: (secretHex: String, pubkeyHex: String) -> T?): T? {
        val nsec = readNsec() ?: return null
        val sec = HavenBridge.decodeNsec(nsec) ?: return null
        val pub = runCatching { HavenBridge.getPublicKey(sec) }.getOrNull()?.lowercase() ?: return null
        return block(sec, pub)
    }

    /** The signed event is the one asked for: this key, this kind. */
    internal fun signedBy(signedJson: String, pubkeyHex: String, kind: Int): Boolean = runCatching {
        val o = Json.parseToJsonElement(signedJson) as JsonObject
        o["pubkey"]?.jsonPrimitive?.content.equals(pubkeyHex, ignoreCase = true) && o["kind"]?.jsonPrimitive?.int == kind
    }.getOrDefault(false)
}
