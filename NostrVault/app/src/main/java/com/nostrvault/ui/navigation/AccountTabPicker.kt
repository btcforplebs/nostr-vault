package com.nostrvault.ui.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Hub
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.ui.Modifier
import com.nostrvault.ui.components.AccountInfo
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * Hold the account picture in the bar (or slide a little), move onto an
 * account, let go: the app switches to it. Same engine and look as the Feed
 * and Vault menus ([DockHoldMenu]), but centered on screen, growing up from
 * the middle button. Above the accounts, then a divider: App settings and
 * Mesh settings (Logen 2026-11-06), so it opens with one account too.
 * iOS: BottomTabBar's account switch menu.
 */
@Stable
object AccountTabPicker {
    /** Rows are accounts, by npub, then the two settings rows by these ids. */
    val menu = DockHoldMenu<String>()

    const val APP_SETTINGS = "menu:app-settings"
    const val MESH_SETTINGS = "menu:mesh-settings"

    /**
     * The rows in menu order. The overlay draws them bottom-up, so this reads
     * top to bottom as: App settings, Mesh settings, a divider, the accounts.
     */
    fun items(npubs: List<String>): List<String> = npubs + listOf(MESH_SETTINGS, APP_SETTINGS)

    /** A settings row's name; null for an account. */
    fun settingsLabel(id: String): String? = when (id) {
        APP_SETTINGS -> "App settings"
        MESH_SETTINGS -> "Mesh settings"
        else -> null
    }
}

/** The account menu, over the whole window above the bar; [accounts] in settings order. [onPick] gets an npub or a settings id. */
@Composable
fun AccountTabPickerOverlay(
    accounts: List<AccountInfo>,
    onPick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val byNpub = accounts.associateBy { it.npub }
    DockHoldMenuOverlay(
        menu = AccountTabPicker.menu,
        items = AccountTabPicker.items(accounts.map { it.npub }),
        row = { id ->
            when (id) {
                AccountTabPicker.APP_SETTINGS ->
                    DockHoldRow(NostrVaultIcons.Settings, "App settings", current = false)
                AccountTabPicker.MESH_SETTINGS -> DockHoldRow(Icons.Filled.Hub, "Mesh settings", current = false, dividerBelow = true)
                else -> {
                    val a = byNpub[id]
                    DockHoldRow(
                        icon = null,
                        label = a?.displayName ?: shortAccountNpub(id),
                        current = a?.isActive == true,
                        hasNews = (a?.unread ?: 0) > 0 && a?.isActive != true,
                        avatar = (a?.hexPubkey ?: "") to a?.avatarUrl,
                        subtitle = shortAccountNpub(id),
                    )
                }
            }
        },
        closeLabel = "Close account menu",
        onPick = onPick,
        modifier = modifier,
        centered = true,
    )
}

/** "npub1abc…wxyz", as iOS AccountSwitcherIdentity.shortNpub. */
internal fun shortAccountNpub(npub: String): String =
    if (npub.length <= 12) npub else npub.take(8) + "…" + npub.takeLast(4)
