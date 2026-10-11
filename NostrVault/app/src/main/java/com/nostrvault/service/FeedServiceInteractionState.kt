package com.nostrvault.service

import com.nostrvault.data.local.EngagementTracker
import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.INTERACTION_SAVE_THROTTLE_MS

    // ══════════════════════════════════════════════════════════════════
    // Engagement
    // ══════════════════════════════════════════════════════════════════

    /**
     * Saves likes, zaps and reactions, at most once per 2 s. A save inside
     * that window runs at its end instead of being dropped: dropping one lost
     * the newest like (or removal) whenever two came close together (iOS #322).
     */
    fun FeedService.saveInteractionState() {
        val wait = INTERACTION_SAVE_THROTTLE_MS - (System.currentTimeMillis() - lastInteractionSaveTime)
        if (wait > 0) {
            if (interactionSaveScheduled) return
            interactionSaveScheduled = true
            scope.launch {
                delay(wait + 50)
                interactionSaveScheduled = false
                saveInteractionState()
            }
            return
        }
        lastInteractionSaveTime = System.currentTimeMillis()

        // Read on Main, with the key, so the state and the account match.
        val key = currentSnapshotKey()
        val state = EngagementTracker.InteractionState(
            likedEventIds = _likedEventIds.value,
            zappedEventIds = _zappedEventIds.value,
            myReactions = _myReactions.value,
            retractedReactionIds = retractedReactionIds,
        )
        interactionSaveJob?.cancel()
        interactionSaveJob = scope.launch(Dispatchers.IO) {
            engagementTracker.saveInteractionState(state, forKey = key)
        }
    }
