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

    /**
     * Leaves [content] as the account's reaction on [noteId], replacing any
     * reaction it already had there (a NIP-09 deletion retracts the old one).
     */
    internal fun FeedService.react(noteId: String, content: String, tags: List<List<String>>?) {
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
            val reactionTags = tags ?: findNote(noteId)?.takeIf { it.id == noteId }.let { note ->
                buildList {
                    add(listOf("e", noteId))
                    note?.pubkey?.let { add(listOf("p", it)) }
                    note?.kind?.let { add(listOf("k", it.toString())) }
                }
            }
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
            notificationManager.showToast(likedToastMessage(content))
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
