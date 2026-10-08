package com.nostrvault.tutorials

/**
 * Every guided tutorial in the app (iOS `TutorialID`). [key] is the storage
 * key, so never change one: a renamed tutorial shows again to everyone who
 * saw it.
 */
enum class TutorialID(val key: String) {
    FILL_YOUR_VAULT("fill-your-vault"),
    FEEDS("feeds"),
    VAULT("vault"),
    WALLET_CONNECT("wallet-connect"),
    POCKET_RELAY("pocket-relay"),
    /** The cards shown while "I already use Nostr" imports your notes. They
     *  teach what Vault and Pocket relay would, so finishing them covers those. */
    IMPORT_TOUR("import-tour");

    /** Fill your vault is about one account's follows, so a second account
     *  gets it again. The page tutorials teach the app, so one run covers
     *  every account on the device. */
    val isPerAccount: Boolean get() = this == FILL_YOUR_VAULT

    /** Bump when a page changes enough that people who saw the old tutorial
     *  should see the new one once. A status from an older version reads as
     *  [TutorialStatus.NOT_STARTED]. */
    val version: Int get() = 1

    /** Tutorials whose lessons this one already gave. Finishing it marks
     *  them done too, so nobody hears the same thing twice. */
    val covers: List<TutorialID> get() = if (this == IMPORT_TOUR) listOf(VAULT, POCKET_RELAY) else emptyList()

    /** Runs inside setup, before there's a feed or a Fill your vault to wait for. */
    val runsDuringSetup: Boolean get() = this == IMPORT_TOUR
}

enum class TutorialStatus(val raw: String) {
    NOT_STARTED("notStarted"), SKIPPED("skipped"), DONE("done");

    companion object {
        fun fromRaw(raw: String): TutorialStatus? = entries.find { it.raw == raw }
    }
}

/** Where progress is kept: SharedPreferences in the app, a map in tests. */
interface TutorialStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
}

/**
 * The rules for when a tutorial may show, with no UI in them so they can be
 * tested alone. Same rules and stored values as iOS `TutorialProgress`.
 */
class TutorialProgress(private val store: TutorialStore) {
    /** The one tutorial on screen, if any. */
    var active: TutorialID? = null
        private set

    /** Set while Fill your vault's bolt or "web of trust is built" card is
     *  up. Fill your vault is already done by then, so nothing else is
     *  active, but no page tutorial may start over that card. */
    var held = false

    fun status(id: TutorialID, account: String): TutorialStatus {
        val raw = store.getString(key(id, account)) ?: return TutorialStatus.NOT_STARTED
        val parts = raw.split("@", limit = 2)
        if (parts.size != 2 || parts[1].toIntOrNull() != id.version) return TutorialStatus.NOT_STARTED
        return TutorialStatus.fromRaw(parts[0]) ?: TutorialStatus.NOT_STARTED
    }

    /** Not seen at this version, nothing else on screen or [held], and for
     *  the page tutorials, Fill your vault finished or skipped first so a new
     *  account never gets two in a row. */
    fun isEligible(id: TutorialID, account: String): Boolean {
        if (account.isEmpty() || active != null || held) return false
        if (status(id, account) != TutorialStatus.NOT_STARTED) return false
        if (id != TutorialID.FILL_YOUR_VAULT && !id.runsDuringSetup) {
            return status(TutorialID.FILL_YOUR_VAULT, account) != TutorialStatus.NOT_STARTED
        }
        return true
    }

    fun startIfEligible(id: TutorialID, account: String): Boolean {
        if (!isEligible(id, account)) return false
        active = id
        return true
    }

    /** From Settings: shows [id] now. Its saved status is left alone until
     *  it's finished or skipped again. */
    fun replay(id: TutorialID) {
        active = id
    }

    /** Done, and so is everything it covers. Only call this when the cards
     *  were actually seen; closing early is [skip]. */
    fun finish(id: TutorialID, account: String) {
        close(id, TutorialStatus.DONE, account)
        for (covered in id.covers) {
            if (status(covered, account) == TutorialStatus.NOT_STARTED) close(covered, TutorialStatus.DONE, account)
        }
    }

    fun skip(id: TutorialID, account: String) = close(id, TutorialStatus.SKIPPED, account)

    fun resetAll(account: String) {
        TutorialID.entries.forEach { store.putString(key(it, account), null) }
        active = null
    }

    private fun close(id: TutorialID, status: TutorialStatus, account: String) {
        if (account.isNotEmpty()) store.putString(key(id, account), "${status.raw}@${id.version}")
        if (active == id) active = null
    }

    companion object {
        const val KEY_PREFIX = "tutorial."

        fun key(id: TutorialID, account: String): String =
            if (id.isPerAccount) "$KEY_PREFIX${id.key}.$account" else "$KEY_PREFIX${id.key}"
    }
}
