package com.nostrvault.service

/**
 * Nuclear unfollow (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md, Logen 2026-11-19):
 * someone keeps reaching you because people you follow follow them. This cuts
 * them and everyone you follow who follows them, in one new follow list,
 * after the vault keeps the current one for Undo. No mute step.
 * The rules, pure for the tests; [ListBackupService.unfollowMany] does the save.
 */
object NuclearUnfollow {
    /** From this many people on, a second warning follows the first. */
    const val DOUBLE_WARN_AT = 25

    /** How many confirm screens come before the save: always one, two at [DOUBLE_WARN_AT] or more. */
    fun warnings(count: Int): Int = if (count >= DOUBLE_WARN_AT) 2 else 1

    /**
     * Who would be unfollowed: [target] if you follow them, then your follows
     * who follow them ([bridges]), never you, each once.
     */
    fun people(target: String, bridges: Collection<String>, follows: Set<String>, me: String): List<String> =
        (listOfNotNull(target.takeIf { it in follows }) + bridges.filter { it in follows })
            .filter { it != me }
            .distinct()

    /** [tags] with every follow of [remove] taken out; all other tags kept as they are, in order. */
    fun tagsWithout(tags: List<List<String>>, remove: Set<String>): List<List<String>> =
        tags.filterNot { it.size >= 2 && it[0] == "p" && it[1] in remove }

    /** Why the save stops once the newest list is known, or null to go on. */
    fun refusal(current: NostrEvent?, remove: Set<String>): String? {
        if (remove.isEmpty()) return "No one is picked. Nothing was changed."
        if (current == null) return "Your follow list wasn't found. Nothing was changed."
        val following = current.tags.filter { it.size >= 2 && it[0] == "p" }.map { it[1] }.toSet()
        if (remove.none { it in following }) return "You don't follow any of them now. Nothing was changed."
        return null
    }

    /** The first warning's title. */
    fun firstWarning(count: Int): String = if (count == 1) "Unfollow 1 person" else "Unfollow $count people"

    /** The second warning, from [DOUBLE_WARN_AT] people on. */
    fun secondWarning(count: Int): String =
        "That's $count people, a big part of your web. Your feed, notifications and Web of Trust will change. " +
            "A backup is saved first, so you can undo it."

    /**
     * The save, through the one safe save ([ListVersionSave]): the newest list must be the one
     * shown ([shownId]), the vault keeps it before anything is signed, and [onBackedUp] gets that
     * kept list once it is safe. The new list is the newest one without [remove], every other
     * tag and the content as they were.
     */
    suspend fun save(
        saver: ListVersionSave,
        me: String,
        shownId: String?,
        remove: Set<String>,
        onBackedUp: suspend (ListVersion) -> Unit,
    ): ListVersionSave.Outcome = saver.save(me, 3, shownId, "change", refuse = { refusal(it, remove) }) { current ->
        // refusal() let it through, so there is a current list, and the vault holds it now.
        val kept = current ?: return@save ListVersionSave.Build.Refuse("Your follow list wasn't found. Nothing was changed.")
        onBackedUp(ListVersion.of(kept))
        ListVersionSave.Build.Ready(tagsWithout(kept.tags, remove), kept.content)
    }
}
