package com.nostrvault.relay

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive

/** What kind of desktop a Vault is. Shown only; it changes no path. iOS DesktopVaultKind. */
@Serializable
enum class DesktopVaultKind {
    @SerialName("mac") MAC,
    @SerialName("linux") LINUX,
    @SerialName("box") BOX,
}

/**
 * One of the owner's always-on desktop Vaults (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.1). It replaces the one-slot
 * [HavenConfig.macRelayURL]. Which fields are set says how it is reached: [meshNpub] only, over FIPS only; [httpsURL]
 * only, over HTTPS only (public data and DMs, never drafts, `/private`, `/chat`, settings, accounts or private files);
 * both, both. Which public lists name the Vault is never stored here: it is read from the newest published lists
 * ([DesktopVaultsLists]), so two devices can't disagree about it. iOS twin: `Models/DesktopVaults.swift`.
 */
@Serializable
data class DesktopVault(
    /** Stable and local, made from the first address the Vault had ([DesktopVaultsRules.idForHost]/[DesktopVaultsRules.idForMesh]). */
    val id: String,
    val name: String = "",
    val kind: DesktopVaultKind = DesktopVaultKind.MAC,
    /** Set: reachable over FIPS. The same npub as its My Devices entry. */
    val meshNpub: String? = null,
    /** Set: reachable over HTTPS, as `https://<base>`, the base kept as typed. */
    val httpsURL: String? = null,
    /** Position in the Desktop Vaults list; sets the order of Vault entries in the public lists (§2.5 rule 2). */
    val order: Int = 0,
) {
    /** The host key of [httpsURL] ([DesktopVaultsLists.hostKey]), null without one. */
    val hostKey: String? get() = httpsURL?.let(DesktopVaultsLists::hostKey)

    /** The name, or the address when none was given. */
    val displayName: String
        get() = name.trim().ifEmpty { hostKey ?: meshNpub?.let { it.take(12) + "…" } ?: "Desktop Vault" }
}

/**
 * The stored Vault list, read one Vault at a time: a Vault a newer app wrote that this one can't read is skipped on
 * its own, an unknown kind reads as [DesktopVaultKind.MAC], and a value that is not a list at all reads as empty
 * (ConfigStore then migrates the slot again, [DesktopVaultsRules.unreadableList]). iOS LossyDesktopVault.
 */
object LossyDesktopVaultList : KSerializer<List<DesktopVault>> {
    private val list = ListSerializer(DesktopVault.serializer())
    private val lenient = Json { ignoreUnknownKeys = true }
    private val kinds = DesktopVaultKind.entries.map { it.name.lowercase() }.toSet()

    override val descriptor: SerialDescriptor = list.descriptor

    override fun serialize(encoder: Encoder, value: List<DesktopVault>) = list.serialize(encoder, value)

    override fun deserialize(decoder: Decoder): List<DesktopVault> {
        val element = (decoder as? JsonDecoder)?.decodeJsonElement() ?: return list.deserialize(decoder)
        val array = element as? JsonArray ?: return emptyList()
        return array.mapNotNull { item ->
            runCatching {
                var obj = item as JsonObject
                val kind = (obj["kind"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                if (kind != null && kind !in kinds) obj = JsonObject(obj + ("kind" to JsonPrimitive("mac")))
                require(obj["id"]?.jsonPrimitive?.isString == true)
                lenient.decodeFromJsonElement(DesktopVault.serializer(), obj)
            }.getOrNull()
        }
    }
}
