package com.nostrvault.service

/**
 * What the wipe alarm says, on the banner and in the notification
 * (docs/LIST_WIPE_ALARM.md, "What the person sees"). Pure, so the wording is
 * tested. [name] is the list as the person calls it ("follows", "bookmark set
 * “reading”"); [day] the date of the new version ("4 Nov").
 */
object ListWipeAlarmText {
    /** Only the encrypted part changed: no public entries were held. */
    private fun privateOnly(a: ListWipeAlarmRule.Alarm) = a.from == 0

    fun headline(a: ListWipeAlarmRule.Alarm, name: String, day: String): String = when {
        privateOnly(a) && a.how == ListWipeAlarmRule.How.EMPTIED -> "The private part of your $name was emptied on $day."
        privateOnly(a) -> "The private part of your $name was cut by more than half on $day."
        a.how == ListWipeAlarmRule.How.SWAPPED -> "Your $name: ${a.lost} of ${a.from} entries were swapped for others on $day."
        a.how == ListWipeAlarmRule.How.DRAINED -> "Your $name went from ${a.from} to ${a.to} in a few steps, the last on $day."
        else -> "Your $name went from ${a.from} to ${a.to} on $day."
    }

    /** "Changed by Amethyst." or the line for an app that didn't name itself. */
    fun changedBy(a: ListWipeAlarmRule.Alarm): String = when {
        a.claimsNostrVault -> "Changed by an app calling itself Nostr Vault. This device didn't make that change."
        a.client != null -> "Changed by ${a.client}."
        else -> "Changed by an app that didn't name itself."
    }

    fun notificationTitle(a: ListWipeAlarmRule.Alarm, name: String): String = when {
        a.how == ListWipeAlarmRule.How.EMPTIED -> "Your $name was emptied"
        privateOnly(a) || a.lost == 0 -> "Your $name lost its private entries"
        a.lost == 1 -> "Your $name lost 1 entry"
        else -> "Your $name lost ${a.lost} entries"
    }

    fun notificationBody(a: ListWipeAlarmRule.Alarm): String = "${changedBy(a)} Tap to recover."
}
