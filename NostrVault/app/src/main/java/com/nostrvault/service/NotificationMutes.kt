package com.nostrvault.service

import com.nostrvault.data.model.MuteRules
import com.nostrvault.ui.navigation.CarriedEvent

/**
 * A note notification the account's mute list hides (word, hashtag, thread):
 * none is shown. Judged on the note it carries, or on its preview text when
 * none came. iOS: LocalNotificationService (`MuteListStore...hides`).
 */
object NotificationMutes {
    fun hides(rules: MuteRules, carried: CarriedEvent?, preview: String, ownHex: String): Boolean {
        if (rules.isEmpty) return false
        // A like or zap on your own post: your own notes are never hidden.
        if (carried != null) return !carried.pubkey.equals(ownHex, ignoreCase = true) && rules.hides(carried.id, carried.content, carried.tags)
        return rules.hidesText(preview)
    }
}
