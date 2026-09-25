package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.JoinedGroupConfig
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/**
 * NIP-29 group chat service.
 * Manages group connections, messaging, membership, and metadata.
 *
 * Port of GroupService.swift.
 */
@Singleton
class GroupService @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) {
    companion object {
        private const val TAG = "GroupService"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val json = Json { ignoreUnknownKeys = true }

    // ── Observable state ──────────────────────────────────────────────

    private val _conversations = MutableStateFlow<List<GroupConversation>>(emptyList())
    val conversations: StateFlow<List<GroupConversation>> = _conversations.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _availableGroups = MutableStateFlow<List<GroupInfo>>(emptyList())
    val availableGroups: StateFlow<List<GroupInfo>> = _availableGroups.asStateFlow()

    val totalUnreadCount: Int
        get() = _conversations.value.sumOf { it.unreadCount }

    // ── Internal state ────────────────────────────────────────────────

    private val relayClients = ConcurrentHashMap<String, WebSocketClient>()
    private val seenGroupEventIds = ConcurrentHashMap.newKeySet<String>()

    // ══════════════════════════════════════════════════════════════════
    // Connection management
    // ══════════════════════════════════════════════════════════════════

    fun connectToGroupRelays() {
        val config = configStore.config.value
        val joinedGroups = config.joinedGroups ?: return

        val relayUrls = joinedGroups.map { it.relayURL }.distinct()
        for (url in relayUrls) {
            connectToRelay(url)
        }
    }

    fun connectToRelay(urlStr: String) {
        if (relayClients.containsKey(urlStr)) return

        val client = WebSocketClient(url = urlStr, scope = scope)
        relayClients[urlStr] = client

        scope.launch {
            client.connectionState.collect { state ->
                if (state == WebSocketClient.ConnectionState.CONNECTED) {
                    subscribeToJoinedGroups(urlStr, client)
                }
            }
        }

        scope.launch {
            client.messages.collect { msg ->
                launch(Dispatchers.Default) { handleGroupRelayMessage(msg, urlStr) }
            }
        }

        client.connect()
    }

    fun disconnectAll() {
        relayClients.values.forEach { it.disconnect() }
        relayClients.clear()
    }

    private fun subscribeToJoinedGroups(relayUrl: String, client: WebSocketClient) {
        val config = configStore.config.value
        val groups = config.joinedGroups?.filter { it.relayURL == relayUrl } ?: return

        for (group in groups) {
            val subId = "group-${group.groupId}"
            // Subscribe to group messages and metadata
            val filter = buildString {
                append("{\"kinds\":[9,11,12,39000,39001,39002,39003]")
                append(",\"#h\":[\"${group.groupId}\"]")
                append(",\"limit\":100}")
            }
            client.send("[\"REQ\",\"$subId\",$filter]")
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Message handling
    // ══════════════════════════════════════════════════════════════════

    private fun handleGroupRelayMessage(message: String, relayUrl: String) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.isEmpty()) return
            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            when (type) {
                "AUTH" -> handleAuthChallenge(parsed, relayUrl)
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val eventObj = parsed[2].jsonObject
                    processGroupEvent(eventObj, relayUrl)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Group relay message parse error: ${e.message}")
        }
    }

    private fun processGroupEvent(eventObj: JsonObject, relayUrl: String) {
        val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        if (!seenGroupEventIds.add(id)) return

        val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
        val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return
        val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
        val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return
        val tags = eventObj["tags"]?.jsonArray?.map { t ->
            t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
        } ?: emptyList()

        val groupId = tags.firstOrNull { it.size >= 2 && it[0] == "h" }?.get(1)
            ?: tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1)
            ?: return

        when (kind) {
            39000 -> handleGroupMetadata(groupId, relayUrl, tags)
            39001 -> handleAdminList(groupId, relayUrl, tags)
            39002 -> handleMemberList(groupId, relayUrl, tags)
            9, 11, 12 -> {
                val isFromMe = pubkey == nostrService.activeHexPubkey
                val message = GroupMessage(
                    id = id,
                    groupId = groupId,
                    senderPubkey = pubkey,
                    content = content,
                    timestamp = createdAt,
                    kind = kind,
                    tags = tags,
                    isFromMe = isFromMe,
                )

                scope.launch(Dispatchers.Main.immediate) {
                    addGroupMessage(groupId, relayUrl, message)
                }
            }
        }
    }

    private fun handleGroupMetadata(groupId: String, relayUrl: String, tags: List<List<String>>) {
        val name = tags.firstOrNull { it.size >= 2 && it[0] == "name" }?.get(1)
        val picture = tags.firstOrNull { it.size >= 2 && it[0] == "picture" }?.get(1)
        val about = tags.firstOrNull { it.size >= 2 && it[0] == "about" }?.get(1)
        val isPrivate = tags.any { it.size >= 1 && it[0] == "private" }
        val isClosed = tags.any { it.size >= 1 && it[0] == "closed" }

        val info = GroupInfo(
            identifier = GroupIdentifier(relayURL = relayUrl, groupId = groupId),
            name = name,
            picture = picture,
            about = about,
            isPrivate = isPrivate,
            isClosed = isClosed,
            memberCount = null,
        )

        scope.launch(Dispatchers.Main.immediate) {
            // Update available groups
            val current = _availableGroups.value.toMutableList()
            val idx = current.indexOfFirst {
                it.identifier.groupId == groupId && it.identifier.relayURL == relayUrl
            }
            if (idx >= 0) current[idx] = info else current.add(info)
            _availableGroups.value = current

            // Update conversation info if joined
            val convos = _conversations.value.toMutableList()
            val convIdx = convos.indexOfFirst {
                it.identifier.groupId == groupId && it.identifier.relayURL == relayUrl
            }
            if (convIdx >= 0) {
                convos[convIdx] = convos[convIdx].copy(info = info)
                _conversations.value = convos
            }
        }
    }

    private fun handleAdminList(groupId: String, relayUrl: String, tags: List<List<String>>) {
        val admins = tags.filter { it.size >= 2 && it[0] == "p" }.map { tag ->
            GroupMember(
                pubkey = tag[1],
                roles = if (tag.size >= 4) listOf(tag[3]) else emptyList(),
            )
        }

        scope.launch(Dispatchers.Main.immediate) {
            val convos = _conversations.value.toMutableList()
            val idx = convos.indexOfFirst {
                it.identifier.groupId == groupId && it.identifier.relayURL == relayUrl
            }
            if (idx >= 0) {
                convos[idx] = convos[idx].copy(admins = admins)
                _conversations.value = convos
            }
        }
    }

    private fun handleMemberList(groupId: String, relayUrl: String, tags: List<List<String>>) {
        val members = tags.filter { it.size >= 2 && it[0] == "p" }.map { tag ->
            GroupMember(pubkey = tag[1])
        }

        scope.launch(Dispatchers.Main.immediate) {
            val convos = _conversations.value.toMutableList()
            val idx = convos.indexOfFirst {
                it.identifier.groupId == groupId && it.identifier.relayURL == relayUrl
            }
            if (idx >= 0) {
                convos[idx] = convos[idx].copy(members = members)
                _conversations.value = convos
            }
        }
    }

    private fun addGroupMessage(groupId: String, relayUrl: String, message: GroupMessage) {
        val convos = _conversations.value.toMutableList()
        val idx = convos.indexOfFirst {
            it.identifier.groupId == groupId && it.identifier.relayURL == relayUrl
        }

        if (idx >= 0) {
            val conv = convos[idx]
            // Dedup optimistic messages
            val isDuplicate = conv.messages.any { existing ->
                existing.content == message.content &&
                    existing.isFromMe == message.isFromMe &&
                    kotlin.math.abs(existing.timestamp - message.timestamp) < 30
            }
            if (isDuplicate) return

            val updatedMessages = (conv.messages + message).sortedBy { it.timestamp }
            val unread = if (message.isFromMe) conv.unreadCount else conv.unreadCount + 1
            convos[idx] = conv.copy(messages = updatedMessages, unreadCount = unread)
        } else {
            convos.add(
                GroupConversation(
                    identifier = GroupIdentifier(relayURL = relayUrl, groupId = groupId),
                    messages = listOf(message),
                    unreadCount = if (message.isFromMe) 0 else 1,
                )
            )
        }

        _conversations.value = convos
        saveGroupCache()
    }

    // ══════════════════════════════════════════════════════════════════
    // Group operations
    // ══════════════════════════════════════════════════════════════════

    suspend fun sendMessage(
        content: String,
        toGroup: GroupIdentifier,
        kind: Int = 9,
        replyTo: String? = null,
    ) {
        // Optimistic UI
        val optimisticId = UUID.randomUUID().toString()
        val optimisticMessage = GroupMessage(
            id = optimisticId,
            groupId = toGroup.groupId,
            senderPubkey = nostrService.activeHexPubkey,
            content = content,
            timestamp = System.currentTimeMillis() / 1000,
            kind = kind,
            tags = emptyList(),
            isFromMe = true,
        )
        addGroupMessage(toGroup.groupId, toGroup.relayURL, optimisticMessage)

        withContext(Dispatchers.IO) {
            val tags = mutableListOf(listOf("h", toGroup.groupId))
            replyTo?.let { tags.add(listOf("e", it, toGroup.relayURL, "reply")) }

            val event = nostrService.signEventAsync(kind = kind, content = content, tags = tags)
                ?: return@withContext

            val eventJson = serializeEvent(event)
            relayClients[toGroup.relayURL]?.send("[\"EVENT\",$eventJson]")
        }
    }

    suspend fun joinGroup(identifier: GroupIdentifier, inviteCode: String? = null) {
        withContext(Dispatchers.IO) {
            val tags = mutableListOf(listOf("h", identifier.groupId))
            inviteCode?.let { tags.add(listOf("code", it)) }

            val event = nostrService.signEventAsync(kind = 9021, content = "", tags = tags)
                ?: return@withContext

            val eventJson = serializeEvent(event)
            relayClients[identifier.relayURL]?.send("[\"EVENT\",$eventJson]")

            // Persist to config
            val joined = JoinedGroupConfig(
                relayURL = identifier.relayURL,
                groupId = identifier.groupId,
                displayName = null,
            )
            configStore.update { config ->
                config.copy(joinedGroups = (config.joinedGroups ?: emptyList()) + joined)
            }

            // Create local conversation
            withContext(Dispatchers.Main.immediate) {
                val convos = _conversations.value.toMutableList()
                if (convos.none { it.identifier == identifier }) {
                    convos.add(GroupConversation(identifier = identifier))
                    _conversations.value = convos
                }
            }

            // Subscribe to group messages
            connectToRelay(identifier.relayURL)
        }
    }

    suspend fun leaveGroup(identifier: GroupIdentifier) {
        withContext(Dispatchers.IO) {
            val tags = listOf(listOf("h", identifier.groupId))
            val event = nostrService.signEventAsync(kind = 9022, content = "", tags = tags)
                ?: return@withContext

            val eventJson = serializeEvent(event)
            relayClients[identifier.relayURL]?.send("[\"EVENT\",$eventJson]")

            // Remove from config
            configStore.update { config ->
                config.copy(
                    joinedGroups = config.joinedGroups?.filter {
                        !(it.groupId == identifier.groupId && it.relayURL == identifier.relayURL)
                    }
                )
            }

            // Remove conversation
            withContext(Dispatchers.Main.immediate) {
                _conversations.value = _conversations.value.filter { it.identifier != identifier }
            }

            saveGroupCache()
        }
    }

    suspend fun createGroup(
        relayURL: String,
        name: String,
        about: String,
        isPrivate: Boolean,
        isClosed: Boolean,
    ) {
        withContext(Dispatchers.IO) {
            val tags = mutableListOf(
                listOf("name", name),
                listOf("about", about),
            )
            if (isPrivate) tags.add(listOf("private"))
            if (isClosed) tags.add(listOf("closed"))

            val event = nostrService.signEventAsync(kind = 9007, content = "", tags = tags)
                ?: return@withContext

            val eventJson = serializeEvent(event)
            relayClients[relayURL]?.send("[\"EVENT\",$eventJson]")
                ?: run {
                    connectToRelay(relayURL)
                    delay(2_000)
                    relayClients[relayURL]?.send("[\"EVENT\",$eventJson]")
                }
        }
    }

    suspend fun editGroupMetadata(
        identifier: GroupIdentifier,
        name: String?,
        about: String?,
        picture: String?,
    ) {
        withContext(Dispatchers.IO) {
            val tags = mutableListOf(listOf("h", identifier.groupId))
            name?.let { tags.add(listOf("name", it)) }
            about?.let { tags.add(listOf("about", it)) }
            picture?.let { tags.add(listOf("picture", it)) }

            val event = nostrService.signEventAsync(kind = 9002, content = "", tags = tags)
                ?: return@withContext

            val eventJson = serializeEvent(event)
            relayClients[identifier.relayURL]?.send("[\"EVENT\",$eventJson]")
        }
    }

    suspend fun addUser(pubkey: String, toGroup: GroupIdentifier, roles: List<String> = emptyList()) {
        withContext(Dispatchers.IO) {
            val tags = mutableListOf(
                listOf("h", toGroup.groupId),
                listOf("p", pubkey),
            )
            for (role in roles) tags.add(listOf("role", role))

            val event = nostrService.signEventAsync(kind = 9000, content = "", tags = tags)
                ?: return@withContext

            val eventJson = serializeEvent(event)
            relayClients[toGroup.relayURL]?.send("[\"EVENT\",$eventJson]")
        }
    }

    suspend fun removeUser(pubkey: String, fromGroup: GroupIdentifier) {
        withContext(Dispatchers.IO) {
            val tags = listOf(
                listOf("h", fromGroup.groupId),
                listOf("p", pubkey),
            )
            val event = nostrService.signEventAsync(kind = 9001, content = "", tags = tags)
                ?: return@withContext

            val eventJson = serializeEvent(event)
            relayClients[fromGroup.relayURL]?.send("[\"EVENT\",$eventJson]")
        }
    }

    suspend fun deleteEvent(eventId: String, fromGroup: GroupIdentifier) {
        withContext(Dispatchers.IO) {
            val tags = listOf(
                listOf("h", fromGroup.groupId),
                listOf("e", eventId),
            )
            val event = nostrService.signEventAsync(kind = 9005, content = "", tags = tags)
                ?: return@withContext

            val eventJson = serializeEvent(event)
            relayClients[fromGroup.relayURL]?.send("[\"EVENT\",$eventJson]")
        }
    }

    fun browseGroups(relayURL: String) {
        val client = relayClients[relayURL] ?: run {
            connectToRelay(relayURL)
            return
        }

        val subId = "browse-${UUID.randomUUID().toString().take(8)}"
        val filter = """{"kinds":[39000],"limit":50}"""
        client.send("[\"REQ\",\"$subId\",$filter]")
    }

    // ══════════════════════════════════════════════════════════════════
    // ViewModel convenience methods
    // ══════════════════════════════════════════════════════════════════

    /** Joined groups as a StateFlow for GroupListScreen. */
    val joinedGroups: StateFlow<List<JoinedGroup>>
        get() = _conversations.map { convos ->
            convos.map { conv ->
                JoinedGroup(
                    relayURL = conv.identifier.relayURL,
                    groupId = conv.identifier.groupId,
                    displayName = conv.info?.name,
                    unreadCount = conv.unreadCount,
                    isPrivate = conv.info?.isPrivate ?: false,
                )
            }
        }.stateIn(scope, SharingStarted.WhileSubscribed(5000), emptyList())

    /** Load joined groups from config and connect. */
    fun loadJoinedGroups() {
        val config = configStore.config.value
        val groups = config.joinedGroups ?: return

        for (g in groups) {
            val id = GroupIdentifier(relayURL = g.relayURL, groupId = g.groupId)
            val existing = _conversations.value.any { it.identifier == id }
            if (!existing) {
                val convos = _conversations.value.toMutableList()
                convos.add(GroupConversation(identifier = id))
                _conversations.value = convos
            }
        }

        connectToGroupRelays()
    }

    /** Connect to a specific group by groupId and relayUrl. */
    fun connectToGroup(groupId: String, relayUrl: String) {
        connectToRelay(relayUrl)
    }

    /** Get group info by groupId and relayUrl. */
    suspend fun getGroupInfo(groupId: String, relayUrl: String): GroupInfo? {
        return _conversations.value.firstOrNull {
            it.identifier.groupId == groupId && it.identifier.relayURL == relayUrl
        }?.info
    }

    /** Get group members by groupId and relayUrl. */
    suspend fun getGroupMembers(groupId: String, relayUrl: String): List<GroupMember> {
        return _conversations.value.firstOrNull {
            it.identifier.groupId == groupId && it.identifier.relayURL == relayUrl
        }?.members ?: emptyList()
    }

    /** Get messages for a group as StateFlow. */
    fun messagesForGroup(groupId: String, relayUrl: String): StateFlow<List<GroupMessage>> {
        return _conversations.map { convos ->
            convos.firstOrNull {
                it.identifier.groupId == groupId && it.identifier.relayURL == relayUrl
            }?.messages ?: emptyList()
        }.stateIn(scope, SharingStarted.WhileSubscribed(5000), emptyList())
    }

    /** Send message by groupId and relayUrl. */
    suspend fun sendMessage(groupId: String, relayUrl: String, content: String) {
        sendMessage(content, GroupIdentifier(relayURL = relayUrl, groupId = groupId))
    }

    /** Join group by groupId and relayUrl. */
    suspend fun joinGroup(groupId: String, relayUrl: String) {
        joinGroup(GroupIdentifier(relayURL = relayUrl, groupId = groupId))
    }

    /** Leave group by groupId and relayUrl. */
    suspend fun leaveGroup(groupId: String, relayUrl: String) {
        leaveGroup(GroupIdentifier(relayURL = relayUrl, groupId = groupId))
    }

    /** Create group with simple parameters. */
    suspend fun createGroup(name: String, about: String, relayUrl: String) {
        createGroup(relayURL = relayUrl, name = name, about = about, isPrivate = false, isClosed = false)
    }

    /** Browse groups from default relay. */
    fun browseGroups(): List<GroupInfo> {
        val config = configStore.config.value
        val defaultRelay = config.blastrRelays.firstOrNull() ?: return emptyList()
        browseGroups(defaultRelay)
        return _availableGroups.value
    }

    /**
     * Distinct relay URLs the user already has group activity on (joined groups
     * + browsed groups), plus their configured relays. Used to populate the
     * relay pickers in group create/browse. Mirrors iOS config.groupRelayURLs.
     */
    fun knownGroupRelays(): List<String> {
        val fromGroups = _conversations.value.map { it.identifier.relayURL } +
            _availableGroups.value.map { it.identifier.relayURL }
        val fromConfig = configStore.config.value.blastrRelays
        return (fromGroups + fromConfig).distinct().filter { it.startsWith("wss://") }
    }

    // ══════════════════════════════════════════════════════════════════
    // Utility
    // ══════════════════════════════════════════════════════════════════

    fun markRead(identifier: GroupIdentifier) {
        val convos = _conversations.value.toMutableList()
        val idx = convos.indexOfFirst { it.identifier == identifier }
        if (idx >= 0) {
            convos[idx] = convos[idx].copy(unreadCount = 0)
            _conversations.value = convos
            saveGroupCache()
        }
    }

    fun markAllAsRead() {
        _conversations.value = _conversations.value.map { it.copy(unreadCount = 0) }
        saveGroupCache()
    }

    fun isAdmin(identifier: GroupIdentifier): Boolean {
        val conv = _conversations.value.firstOrNull { it.identifier == identifier } ?: return false
        return conv.admins.any { it.pubkey == nostrService.activeHexPubkey }
    }

    private fun handleAuthChallenge(parsed: JsonArray, relayUrl: String) {
        if (parsed.size < 2) return
        val challenge = parsed[1].jsonPrimitive.contentOrNull ?: return

        scope.launch(Dispatchers.IO) {
            val tags = listOf(
                listOf("relay", relayUrl),
                listOf("challenge", challenge),
            )
            val authEvent = try {
                nostrService.signEventAsync(
                    kind = 22242, content = "", tags = tags, forceOwner = true,
                )
            } catch (e: Exception) {
                Log.e(TAG, "AUTH to $relayUrl not signed: ${e.message}")
                null
            } ?: return@launch

            val eventJson = serializeEvent(authEvent)
            relayClients[relayUrl]?.send("[\"AUTH\",$eventJson]")
        }
    }

    private fun saveGroupCache() {
        scope.launch(Dispatchers.IO) {
            try {
                val dir = configStore.config.value.appSupportDir ?: return@launch
                val dirFile = File(dir)
                if (!dirFile.exists()) dirFile.mkdirs()
                val file = File(dir, "group_cache.json")
                file.writeText(json.encodeToString(
                    kotlinx.serialization.builtins.ListSerializer(GroupConversation.serializer()),
                    _conversations.value
                ))
            } catch (e: Exception) {
                Log.w(TAG, "Group cache save failed: ${e.message}")
            }
        }
    }

    private fun serializeEvent(event: NostrEvent): String = EventPublisher.serializeSignedEvent(event)
}

// ── Data models ───────────────────────────────────────────────────

@Serializable
data class GroupIdentifier(
    val relayURL: String,
    val groupId: String,
)

@Serializable
data class GroupInfo(
    val identifier: GroupIdentifier,
    val name: String?,
    val picture: String?,
    val about: String?,
    val isPrivate: Boolean = false,
    val isClosed: Boolean = false,
    val memberCount: Int? = null,
)

@Serializable
data class GroupConversation(
    val identifier: GroupIdentifier,
    val info: GroupInfo? = null,
    val messages: List<GroupMessage> = emptyList(),
    val unreadCount: Int = 0,
    val members: List<GroupMember> = emptyList(),
    val admins: List<GroupMember> = emptyList(),
)

@Serializable
data class GroupMessage(
    val id: String,
    val groupId: String,
    val senderPubkey: String,
    val content: String,
    val timestamp: Long,
    val kind: Int,
    val tags: List<List<String>> = emptyList(),
    val isFromMe: Boolean = false,
)

@Serializable
data class GroupMember(
    val pubkey: String,
    val roles: List<String> = emptyList(),
)

@Serializable
data class JoinedGroup(
    val relayURL: String,
    val groupId: String,
    val displayName: String? = null,
    val unreadCount: Int = 0,
    val isPrivate: Boolean = false,
)
