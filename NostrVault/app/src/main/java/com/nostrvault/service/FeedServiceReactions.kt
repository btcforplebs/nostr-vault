package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.EngagementTracker
import com.nostrvault.data.model.*
import com.nostrvault.data.remote.LookupSocketPool
import com.nostrvault.ui.components.likedToastMessage
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.util.UUID
import com.nostrvault.service.FeedService.Companion.TAG
import com.nostrvault.ui.components.ReactionChoice

    /**
     * Leaves [content] as the account's reaction on [noteId], replacing any
     * reaction it already had there (a NIP-09 deletion retracts the old one).
     */
    internal fun FeedService.react(noteId: String, content: String, tags: List<List<String>>?, emojiTag: List<String>? = null) {
        val previous = _myReactions.value[noteId]
        val wasLiked = noteId in _likedEventIds.value
        if (wasLiked && previous?.content == content) return
        // A removal still in its undo window becomes final: this is a new reaction.
        notificationManager.commitUnlikeCountdown()
        val oldId = previous?.eventId
        if (oldId != null) {
            retract(oldId)
        } else if (wasLiked && noteId !in pendingReactionTokens) {
            retractUnknown(noteId)
        }

        val token = Any()
        pendingReactionTokens[noteId] = token
        _likedEventIds.value = _likedEventIds.value + noteId
        _myReactions.value = _myReactions.value + (noteId to EngagementTracker.MyReaction(content))
        if (!wasLiked) bumpReactionCount(noteId, +1)
        saveInteractionState()

        scope.launch {
            // iOS tags the author (p) and kind (k) too; without p the liked
            // post's author is unknown and Relay > Likes > Given cannot ask
            // that author's relays for it.
            // Only the note itself: a repost found under its original's id
            // would name the reposter and kind 6.
            val reactionTags = (tags ?: findNote(noteId)?.takeIf { it.id == noteId }.let { note ->
                buildList {
                    add(listOf("e", noteId))
                    note?.pubkey?.let { add(listOf("p", it)) }
                    note?.kind?.let { add(listOf("k", it.toString())) }
                }
            }) + ReactionChoice.emojiTags(content, emojiTag)
            val event = withContext(Dispatchers.IO) {
                runCatching { nostrService.signEventAsync(kind = 7, content = content, tags = reactionTags) }
                    .onFailure { Log.e(TAG, "like not signed: ${it.message}") }.getOrNull()
            }
            // Changed or removed while signing: this one never goes out.
            if (pendingReactionTokens[noteId] !== token) return@launch
            pendingReactionTokens.remove(noteId)
            if (event == null) {
                unlikeNote(noteId)
                notificationManager.showError("Like failed: your signer didn't answer")
                return@launch
            }
            withContext(Dispatchers.IO) { nostrService.postEvent(event) }
            _myReactions.value = _myReactions.value + (noteId to EngagementTracker.MyReaction(content, event.id))
            saveInteractionState()
            keepLikedNoteLocally(noteId)
            // A like signed by a remote signer takes a round trip; with
            // nothing on screen there was no telling one that went out
            // from one the signer never answered (iOS #295).
            notificationManager.showFeedback(likedToastMessage(content), com.nostrvault.ui.theme.NostrVaultIcons.HeartFilled)
        }
    }

    /**
     * Clears the account's reaction on [noteId] at once, with an Undo pill.
     * When the pill runs out the reaction is deleted on the network.
     */
    internal fun FeedService.removeReaction(noteId: String) {
        if (noteId !in _likedEventIds.value) return
        val removed = _myReactions.value[noteId]
        val wasSigning = pendingReactionTokens.remove(noteId) != null

        _likedEventIds.value = _likedEventIds.value - noteId
        _myReactions.value = _myReactions.value - noteId
        // An echo of it arriving during the countdown must not bring it back.
        removed?.eventId?.let { retractedReactionIds = retractedReactionIds + it }
        bumpReactionCount(noteId, -1)
        saveInteractionState()

        // Still being signed: dropping the token already stops it going out.
        if (wasSigning) return
        notificationManager.startUnlikeCountdown(
            onUnlike = {
                val eventId = removed?.eventId
                if (eventId != null) retract(eventId) else retractUnknown(noteId)
            },
            onUndo = {
                // Reacting again during the countdown commits it first, so
                // Undo only ever restores a note left without a reaction.
                if (noteId !in _likedEventIds.value) {
                    removed?.eventId?.let { retractedReactionIds = retractedReactionIds - it }
                    _likedEventIds.value = _likedEventIds.value + noteId
                    if (removed != null) _myReactions.value = _myReactions.value + (noteId to removed)
                    bumpReactionCount(noteId, +1)
                    saveInteractionState()
                }
            },
        )
    }

    /**
     * Publishes a NIP-09 deletion for one of the account's reactions and
     * remembers it, so relays that keep serving it cannot bring it back.
     */
    private fun FeedService.retract(reactionId: String) {
        retractedReactionIds = retractedReactionIds + reactionId
        saveInteractionState()
        scope.launch(Dispatchers.IO) {
            val event = runCatching {
                nostrService.signEventAsync(kind = 5, content = "", tags = EngagementTracker.reactionDeletionTags(reactionId))
            }.onFailure { Log.e(TAG, "reaction deletion not signed: ${it.message}") }.getOrNull() ?: return@launch
            nostrService.postEvent(event)
        }
    }

    /**
     * For a like saved before reactions kept their event id: looks the
     * account's reactions to the note up on its relays and deletes them,
     * except one made since (the note's current reaction).
     */
    private fun FeedService.retractUnknown(noteId: String) {
        scope.launch {
            val ids = fetchOwnReactionIds(noteId)
            val current = _myReactions.value[noteId]?.eventId
            for (id in ids) {
                if (id != current && id !in retractedReactionIds) retract(id)
            }
        }
    }

    /**
     * Ids of the active account's own reactions (kind 7) to [noteId], from
     * the account's relay and the blastr relays.
     */
    private suspend fun FeedService.fetchOwnReactionIds(noteId: String): List<String> = withContext(Dispatchers.IO) {
        val pubkey = nostrService.activeHexPubkey
        if (pubkey.isEmpty()) return@withContext emptyList()
        val config = configStore.config.value
        val urls = buildList {
            addAll(config.writeRelays)
            config.nostrURL?.takeIf { it.isNotBlank() }?.let { add(it) }
        }.filterNot { NostrService.isLoopbackRelay(it) }.distinctBy { LookupSocketPool.relayKey(it) }
        val ids = java.util.Collections.synchronizedSet(mutableSetOf<String>())
        val filter = """{"kinds":[7],"authors":["$pubkey"],"#e":["$noteId"],"limit":20}"""
        urls.map { url ->
            async {
                lookupPool.query(url, "myrx-${UUID.randomUUID().toString().take(6)}", listOf(filter), 5_000L) { msg ->
                    try {
                        val parsed = json.parseToJsonElement(msg).jsonArray
                        if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "EVENT") return@query
                        val ev = parsed[2].jsonObject
                        if (ev["kind"]?.jsonPrimitive?.intOrNull != 7) return@query
                        if (ev["pubkey"]?.jsonPrimitive?.contentOrNull != pubkey) return@query
                        val tags = ev["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" } }.orEmpty()
                        if (tags.none { it.size >= 2 && it[0] == "e" && it[1] == noteId }) return@query
                        ev["id"]?.jsonPrimitive?.contentOrNull?.let { ids.add(it) }
                    } catch (_: Exception) {}
                }
            }
        }.awaitAll()
        ids.toList()
    }

    /** The account's own reactions seen on relays: fills in notes with no known reaction. */
    internal fun FeedService.applySelfReactions(reactions: List<EngagementTracker.ReactionEvent>) {
        if (reactions.isEmpty()) return
        val mine = EngagementTracker.detectSelfReactions(reactions, nostrService.activeHexPubkey, retractedReactionIds)
        if (mine.isEmpty()) return
        val liked = _likedEventIds.value
        // One made here (signed, or still signing) is the one to show and to
        // delete on removal; an older echo of a replaced one must not win.
        val fresh = mine.filterKeys { it !in _myReactions.value }
        if (fresh.isEmpty() && liked.containsAll(mine.keys)) return
        _likedEventIds.value = liked + mine.keys
        _myReactions.value = _myReactions.value + fresh
        saveInteractionState()
    }

    internal fun FeedService.bumpReactionCount(noteId: String, by: Int) {
        val stats = _noteStats.value.toMutableMap()
        val existing = stats[noteId] ?: NoteStats()
        stats[noteId] = existing.copy(reactionCount = maxOf(0, existing.reactionCount + by))
        _noteStats.value = stats
    }

    /**
     * The reaction button. A tap ([emoji] null) reacts with the default
     * reaction, or takes the account's reaction back when it has one. A
     * picked [emoji] (tapback bar or picker) is sent instead, replacing any
     * other reaction; picking the one already sent takes it back. iOS #322.
     */
    internal fun FeedService.likeNoteImpl(noteId: String, emoji: String? = null, tags: List<List<String>>? = null, emojiTag: List<String>? = null) {
        val isLiked = noteId in _likedEventIds.value
        val current = _myReactions.value[noteId]?.content
        val change = if (emoji == null) {
            ReactionChoice.forTap(isLiked, configStore.config.value.defaultReactionEmoji)
        } else {
            ReactionChoice.forPick(isLiked, current, emoji)
        }
        when (change) {
            is ReactionChoice.Change.React -> react(noteId, change.content, tags, emojiTag)
            ReactionChoice.Change.Remove -> removeReaction(noteId)
        }
    }

    /** Repost a note (kind 6 for kind-1 notes, kind 16 + k-tag otherwise, per NIP-18). */
    internal fun FeedService.repostNoteImpl(noteId: String) {
        val existing = _repostedEventIds.value
        if (noteId in existing) return
        _repostedEventIds.value = existing + noteId

        // Taken at hand-off, so a switch while it signs refuses it rather
        // than reposting as the new account.
        val lock = nostrService.lockPostingAccount()
        scope.launch(Dispatchers.IO) {
            // NIP-18: always repost the ORIGINAL event, not a repost wrapper. For kind
            // 6 notes, repostedEventId points to the original kind-1 event (the only
            // kind this app has ever wrapped in kind 6).
            val note = findNote(noteId)
            val originalId = note?.repostedEventId ?: noteId
            // A bare repost still carries the reposter's pubkey.
            val originalPubkey = note?.effectiveAuthor
            val originalKind = note?.effectiveKind ?: 1

            val rawEvent = rawEventCache[originalId] ?: ""
            val config = configStore.config.value
            // NIP-18: e tag MUST include a relay URL as its third entry.
            val relayHint = config.activeFeedRelays.firstOrNull()
                ?: config.activeBlastrRelays.firstOrNull()
                ?: (config.nostrURL ?: "")

            // NIP-18: kind 6 is reserved for reposting kind-1 notes. Anything else
            // (e.g. a kind-30023 long-form article) needs kind 16 with a "k" tag
            // naming the original kind, or most clients will reject/ignore it.
            val repostKind = if (originalKind == 1) 6 else 16
            val tags = buildList {
                add(listOf("e", originalId, relayHint))
                originalPubkey?.let { add(listOf("p", it)) }
                if (repostKind == 16) add(listOf("k", originalKind.toString()))
            }
            val event = runCatching {
                nostrService.signEventAsync(kind = repostKind, content = rawEvent, tags = tags, lockedTo = lock)
                    ?.also { nostrService.requireStillPostingAs(lock, it.pubkey) }
            }
                .onFailure { Log.e(TAG, "repost not signed: ${it.message}") }.getOrNull()
            if (event != null) {
                nostrService.postEvent(event)
            } else {
                // Nothing was published — undo the optimistic repost.
                _repostedEventIds.value = _repostedEventIds.value - noteId
                val stats = _noteStats.value.toMutableMap()
                val st = stats[noteId] ?: NoteStats()
                stats[noteId] = st.copy(repostCount = maxOf(0, st.repostCount - 1))
                _noteStats.value = stats
            }
        }

        val stats = _noteStats.value.toMutableMap()
        val existing2 = stats[noteId] ?: NoteStats()
        stats[noteId] = existing2.copy(repostCount = existing2.repostCount + 1)
        _noteStats.value = stats
    }
