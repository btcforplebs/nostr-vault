package com.nostrvault.service

/**
 * The one safe save every new version of a list made from List backups goes
 * through (a restore, a merge), so the rules live in one place
 * (RESEARCH/NV_LIST_PROTECTION_PLAN.md). Never called without a tap:
 * 1. the newest list is fetched again and must be the one the person was shown;
 * 2. the vault must hold that newest list first, so the change can be undone;
 * 3. the new tags are signed by the list's account, dated after the newest;
 * 4. the vault must accept it, then it goes to the person's relays and the app's copy is reloaded.
 * [steps] does the network and signing; this decides. Pure for the tests.
 */
class ListVersionSave(private val steps: Steps) {
    interface Steps {
        /** The active account's hex pubkey right now. */
        fun activeAccount(): String

        /** The newest copy of the list, by the rule every list edit uses; a failure carries what to tell the person. */
        suspend fun newest(): Result<NostrEvent?>

        /** Whether the vault holds [current] (already, or once sent to it), so the change can be undone. */
        suspend fun keepUndoCopy(current: NostrEvent): Boolean

        /** Signs as the list's account, dated [notBefore] or later; null when it can't. */
        suspend fun sign(kind: Int, content: String, tags: List<List<String>>, notBefore: Long): NostrEvent?

        /** Whether the vault accepted [signed]. */
        suspend fun store(signed: NostrEvent): Boolean

        /** Sends [signed] to the account's relays and reloads the app's copy of the list. */
        suspend fun send(signed: NostrEvent)
    }

    /** The list a save signs, or why it isn't saved. */
    sealed interface Build {
        data class Ready(val tags: List<List<String>>, val content: String) : Build
        data class Refuse(val message: String) : Build
    }

    sealed interface Outcome {
        data class Saved(val event: NostrEvent) : Outcome

        /** Nothing was signed, or what was is said in [message]. [changed]: the list changed since it was shown. */
        data class Refused(val message: String, val changed: Boolean = false) : Outcome
    }

    /**
     * Saves a new version of [pubkey]'s [kind] list. [shownId]: the newest list the
     * person was shown (null: none). [verb] names the action in messages
     * ("restore", "merge"). [refuse] may stop it once the newest list is known;
     * [build] makes the tags and content, after the undo copy is kept.
     */
    suspend fun save(
        pubkey: String,
        kind: Int,
        shownId: String?,
        verb: String,
        refuse: (NostrEvent?) -> String? = { null },
        build: suspend (NostrEvent?) -> Build,
    ): Outcome {
        val name = ListShrinkRule.name(kind)
        val current = steps.newest().getOrElse {
            return Outcome.Refused(it.message ?: "Your newest $name can't be checked. Nothing was changed.")
        }
        if (current?.id != shownId) {
            return Outcome.Refused("Your $name changed while this was open. Nothing was changed; look again and retry.", changed = true)
        }
        refuse(current)?.let { return Outcome.Refused(it) }
        if (current != null && !steps.keepUndoCopy(current)) {
            return Outcome.Refused("Your vault couldn't keep a copy of your newest $name, so the $verb couldn't be undone. Nothing was changed.")
        }
        val (tags, content) = when (val built = build(current)) {
            is Build.Refuse -> return Outcome.Refused(built.message)
            is Build.Ready -> built.tags to built.content
        }
        val signed = steps.sign(kind, content, tags, ListMerge.notBefore(current))
        if (signed == null || signed.pubkey != pubkey) return Outcome.Refused("The list couldn't be signed. Nothing was changed.")
        if (steps.activeAccount() != pubkey) return Outcome.Refused("You switched accounts during the $verb. Nothing was changed.")
        if (!steps.store(signed)) return Outcome.Refused("Your vault refused the ${verb}d $name. Nothing was sent to your relays.")
        // send() goes through the active account's relays: still this one?
        if (steps.activeAccount() != pubkey) {
            return Outcome.Refused(
                "You switched accounts during the $verb. Your vault kept the ${verb}d list; this app didn't send it to your relays. Switch back and check it.",
            )
        }
        steps.send(signed)
        return Outcome.Saved(signed)
    }
}
