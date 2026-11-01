package com.nostrvault.ui.navigation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.ui.Modifier
import com.nostrvault.ui.components.AccountInfo

/**
 * Hold the account picture in the bar (or slide a little), move onto an
 * account, let go: the app switches to it. Same engine and look as the Feed
 * and Vault menus ([DockHoldMenu]). Only with more than one account; with one
 * there is nothing to switch to. iOS: BottomTabBar's account switch menu.
 */
@Stable
object AccountTabPicker {
    /** Rows are accounts, by npub. */
    val menu = DockHoldMenu<String>()
}

/** The account menu, over the whole window above the bar; [accounts] in settings order. */
@Composable
fun AccountTabPickerOverlay(
    accounts: List<AccountInfo>,
    onPick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val byNpub = accounts.associateBy { it.npub }
    DockHoldMenuOverlay(
        menu = AccountTabPicker.menu,
        items = accounts.map { it.npub },
        row = { npub ->
            val a = byNpub[npub]
            DockHoldRow(
                icon = null,
                label = a?.displayName ?: shortAccountNpub(npub),
                current = a?.isActive == true,
                hasNews = (a?.unread ?: 0) > 0 && a?.isActive != true,
                avatar = (a?.hexPubkey ?: "") to a?.avatarUrl,
                subtitle = shortAccountNpub(npub),
            )
        },
        closeLabel = "Close account list",
        onPick = onPick,
        modifier = modifier,
    )
}

/** "npub1abc…wxyz", as iOS AccountSwitcherIdentity.shortNpub. */
internal fun shortAccountNpub(npub: String): String =
    if (npub.length <= 12) npub else npub.take(8) + "…" + npub.takeLast(4)
