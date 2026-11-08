package com.nostrvault.ui.screens.settings

import com.nostrvault.fips.MediaServerVaults
import com.nostrvault.relay.HavenConfig

/**
 * Settings › Media Servers as an unsaved draft (Logen via Tod, 2026-11-08). Adding or removing a typed server, a
 * suggested one, or a vault under "Your Vaults" only changes the list on screen. Save stores the typed servers and
 * publishes the media server list (kind 10063) once; leaving with unsaved changes asks Save or Discard.
 * Same rule as iOS `MediaServersDraft` and Settings › Relays (`RelayDraft`). Pure for the tests.
 */
data class MediaServersDraft(
    /** The typed servers when the screen opened, or at the last Save. */
    val savedMirrors: List<String>,
    /** The typed servers on screen. */
    val mirrors: List<String> = savedMirrors,
    /** Your Vaults choices not saved yet: vault npub → listed. */
    val vaults: Map<String, Boolean> = emptyMap(),
) {
    /** Servers added or removed, plus vaults added or taken off. */
    val changeCount: Int
        get() {
            val saved = savedMirrors.toSet()
            val now = mirrors.toSet()
            return (now - saved).size + (saved - now).size + vaults.size
        }

    val hasChanges: Boolean get() = changeCount > 0

    /** Adds a typed or suggested server to the list on screen; unchanged when blank or already there. */
    fun addMirror(typed: String): MediaServersDraft {
        val url = normalized(typed) ?: return this
        return if (url in mirrors) this else copy(mirrors = mirrors + url)
    }

    fun removeMirror(url: String): MediaServersDraft = copy(mirrors = mirrors - url)

    /**
     * Add ([list] true) or Take off on a vault row. [listedNow] is whether it is listed without this draft (published
     * list plus saved choices); going back to that leaves nothing to save.
     */
    fun setVault(npub: String, list: Boolean, listedNow: Boolean): MediaServersDraft =
        copy(vaults = if (list == listedNow) vaults - npub else vaults + (npub to list))

    /** [config] with this draft's vault choices on it: what the rows show now, and what Save stores. */
    fun applyVaults(config: HavenConfig): HavenConfig =
        vaults.entries.fold(config) { c, (npub, list) -> MediaServerVaults.choose(c, npub, list) }

    /** What Save stores before its one publish: the typed servers and the vault choices. */
    fun saveInto(config: HavenConfig, nowSeconds: Long): HavenConfig {
        val withVaults = applyVaults(config)
        return if (mirrors == savedMirrors) withVaults
        else withVaults.copy(blossomMirrors = mirrors, blossomMirrorsUpdatedAt = nowSeconds)
    }

    /** After Save: the screen's list is the saved list. */
    fun saved(): MediaServersDraft = MediaServersDraft(savedMirrors = mirrors)

    /** Discard: back to the saved list, nothing to publish. */
    fun discarded(): MediaServersDraft = MediaServersDraft(savedMirrors = savedMirrors)

    /** The typed servers changed elsewhere (another device's list adopted): follow them unless there are edits here. */
    fun savedMirrorsChanged(mirrors: List<String>): MediaServersDraft =
        if (hasChanges || mirrors == savedMirrors) this else MediaServersDraft(savedMirrors = mirrors)

    companion object {
        /** "https://" in front when no scheme was typed. Null for an empty entry. */
        fun normalized(typed: String): String? {
            val t = typed.trim()
            if (t.isEmpty()) return null
            return if (t.startsWith("https://") || t.startsWith("http://")) t else "https://$t"
        }
    }
}
