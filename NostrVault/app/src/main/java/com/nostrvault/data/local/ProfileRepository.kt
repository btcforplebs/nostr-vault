package com.nostrvault.data.local

import android.content.Context
import com.nostrvault.data.model.FeedProfile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.io.File

/**
 * Port of ProfileRepository.swift -- profile and relay-list cache persistence.
 * Pure JSON file I/O with no UI dependencies.
 */
object ProfileRepository {

    private val json = Json { ignoreUnknownKeys = true; prettyPrint = false }
    private var dataDir: File? = null

    val isInitialized: Boolean get() = dataDir != null

    fun init(context: Context) {
        dataDir = File(context.filesDir, "nostrvault_data").also { it.mkdirs() }
    }

    private val profilesFile: File? get() = dataDir?.let { File(it, "profiles.json") }
    private val relayListsFile: File? get() = dataDir?.let { File(it, "relay_lists.json") }
    private val outboxRelaysFile: File? get() = dataDir?.let { File(it, "outbox_relays.json") }
    private val dmRelayListsFile: File? get() = dataDir?.let { File(it, "dm_relay_lists.json") }
    private val serverListsFile: File? get() = dataDir?.let { File(it, "server_lists.json") }

    // ---- Load from disk ----

    fun loadProfiles(): Map<String, FeedProfile> = profilesFile?.let { loadMap(it) } ?: emptyMap()

    fun loadRelayLists(): Map<String, List<String>> = relayListsFile?.let { loadStringListMap(it) } ?: emptyMap()

    fun loadOutboxRelays(): Map<String, List<String>> = outboxRelaysFile?.let { loadStringListMap(it) } ?: emptyMap()

    fun loadDMRelayLists(): Map<String, List<String>> = dmRelayListsFile?.let { loadStringListMap(it) } ?: emptyMap()

    fun loadServerLists(): Map<String, List<String>> = serverListsFile?.let { loadStringListMap(it) } ?: emptyMap()

    // ---- Save to disk (background) ----

    suspend fun saveProfiles(profiles: Map<String, FeedProfile>) = withContext(Dispatchers.IO) {
        saveToFile(profilesFile ?: return@withContext, json.encodeToString(profiles))
    }

    suspend fun saveRelayLists(lists: Map<String, List<String>>) = withContext(Dispatchers.IO) {
        saveToFile(relayListsFile ?: return@withContext, json.encodeToString(lists))
    }

    suspend fun saveOutboxRelays(lists: Map<String, List<String>>) = withContext(Dispatchers.IO) {
        saveToFile(outboxRelaysFile ?: return@withContext, json.encodeToString(lists))
    }

    suspend fun saveDMRelayLists(lists: Map<String, List<String>>) = withContext(Dispatchers.IO) {
        saveToFile(dmRelayListsFile ?: return@withContext, json.encodeToString(lists))
    }

    suspend fun saveServerLists(lists: Map<String, List<String>>) = withContext(Dispatchers.IO) {
        saveToFile(serverListsFile ?: return@withContext, json.encodeToString(lists))
    }

    // ---- Event parsing (pure functions) ----

    /**
     * Parse Kind 0 (Metadata) event content into profile field updates.
     * Returns the updated profile and whether any field changed, or null if invalid JSON.
     */
    fun parseMetadataContent(
        content: String,
        pubkey: String,
        existingProfile: FeedProfile?,
    ): Pair<FeedProfile, Boolean>? {
        val metadata = try {
            json.parseToJsonElement(content) as? JsonObject ?: return null
        } catch (_: Exception) {
            return null
        }

        val name = metadata["name"]?.jsonPrimitive?.contentOrNull
        val displayName = metadata["display_name"]?.jsonPrimitive?.contentOrNull
        val picture = metadata["picture"]?.jsonPrimitive?.contentOrNull
        val banner = metadata["banner"]?.jsonPrimitive?.contentOrNull
        val nip05 = metadata["nip05"]?.jsonPrimitive?.contentOrNull
        val about = metadata["about"]?.jsonPrimitive?.contentOrNull
        val lud16 = metadata["lud16"]?.jsonPrimitive?.contentOrNull
        val lud06 = metadata["lud06"]?.jsonPrimitive?.contentOrNull
        val website = metadata["website"]?.jsonPrimitive?.contentOrNull

        val existing = existingProfile ?: FeedProfile(pubkey = pubkey)
        var changed = false

        val profile = existing.copy(
            name = name.also { if (it != existing.name) changed = true },
            displayName = displayName.also { if (it != existing.displayName) changed = true },
            pictureURL = picture.also { if (it != existing.pictureURL) changed = true },
            bannerURL = banner.also { if (it != existing.bannerURL) changed = true },
            nip05 = nip05.also { if (it != existing.nip05) changed = true },
            about = about.also { if (it != existing.about) changed = true },
            lud16 = lud16.also { if (it != existing.lud16) changed = true },
            lud06 = lud06.also { if (it != existing.lud06) changed = true },
            website = website.also { if (it != existing.website) changed = true },
        )

        return profile to changed
    }

    /**
     * Parse Kind 10002 (NIP-65 Relay List Metadata) tags.
     * Tags: ["r", relay_url, "read" | "write"], no marker = both.
     */
    fun parseRelayListTags(tags: List<List<String>>): Pair<List<String>, List<String>> {
        val inbox = mutableListOf<String>()
        val write = mutableListOf<String>()
        for (tag in tags) {
            if (tag.size < 2 || tag[0] != "r") continue
            val url = tag[1]
            if (!isValidRelayUrl(url)) continue
            val marker = if (tag.size >= 3) tag[2] else ""
            if (marker == "read" || marker == "") inbox.add(url)
            if (marker == "write" || marker == "") write.add(url)
        }
        return inbox to write
    }

    /**
     * Parse Kind 10050 (NIP-17 DM Relay List) tags. NIP-17 tags are
     * ["relay", url]; ["r", url] is also read because older Nostr Vault builds
     * published that shape.
     */
    fun parseDMRelayListTags(tags: List<List<String>>): List<String> =
        tags.filter { it.size >= 2 && (it[0] == "relay" || it[0] == "r") && isValidRelayUrl(it[1]) }
            .map { it[1] }
            .distinct()

    /** Parse Kind 10063 (BUD-03 User Server List) tags. */
    fun parseServerListTags(tags: List<List<String>>): List<String> =
        tags.filter { it.size >= 2 && it[0] == "server" }.map { it[1] }

    /** Reject relay URLs with spaces or missing wss:// scheme. */
    private fun isValidRelayUrl(url: String): Boolean =
        url.startsWith("wss://") && !url.contains(' ')

    /** Parse Kind 10000 (Mute List) p-tags into blocked hex pubkeys. */
    fun parseMuteListPTags(tags: List<List<String>>): List<String> =
        tags.filter { it.size >= 2 && it[0] == "p" }.map { it[1] }

    // ---- Private helpers ----

    private inline fun <reified T> loadMap(file: File): Map<String, T> = try {
        if (file.exists()) json.decodeFromString(file.readText()) else emptyMap()
    } catch (_: Exception) {
        emptyMap()
    }

    private fun loadStringListMap(file: File): Map<String, List<String>> = try {
        if (file.exists()) json.decodeFromString(file.readText()) else emptyMap()
    } catch (_: Exception) {
        emptyMap()
    }

    private fun saveToFile(file: File, content: String) {
        try {
            dataDir?.mkdirs()
            file.writeText(content)
        } catch (_: Exception) { }
    }
}
