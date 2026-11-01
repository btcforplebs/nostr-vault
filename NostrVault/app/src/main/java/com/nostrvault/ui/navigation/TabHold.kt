package com.nostrvault.ui.navigation

import android.view.View
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.semantics.CustomAccessibilityAction
import com.nostrvault.data.model.FeedMenuSettings
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.VaultMode

/**
 * A dock button with a hold menu: the Feed tab (feeds), the Vault tab (its
 * pages) or the account picture (accounts). The bar's NavTab draws either the same way; this says which
 * [DockHoldMenu] it drives and what a pick does.
 */
internal sealed class TabHold {
    abstract val isOpen: Boolean
    abstract val isPressed: Boolean
    /** What the tab shows now, spoken with it. */
    abstract val shownName: String?
    /** One accessibility action per menu row; [current] is the tab's latest hold. */
    abstract fun actions(current: () -> TabHold?): List<CustomAccessibilityAction>

    class Feed(val onPick: (FeedMode) -> Unit) : TabHold() {
        override val isOpen get() = FeedTabPicker.menu.isOpen
        override val isPressed get() = FeedTabPicker.menu.isPressed
        override val shownName get() = FeedTabPicker.shownMode?.displayName
        override fun actions(current: () -> TabHold?) = FeedMenuSettings.menuModes().map { mode ->
            CustomAccessibilityAction(mode.displayName) { (current() as? Feed)?.onPick?.invoke(mode); true }
        }
    }

    class Vault(val onPick: (VaultMode) -> Unit) : TabHold() {
        override val isOpen get() = VaultTabPicker.menu.isOpen
        override val isPressed get() = VaultTabPicker.menu.isPressed
        override val shownName get() = VaultTabPicker.shownMode?.displayName
        override fun actions(current: () -> TabHold?) =
            VaultTabPicker.menu.listed.ifEmpty { VaultMode.menu(zapsOnly = false) }.map { mode ->
                CustomAccessibilityAction(mode.displayName) { (current() as? Vault)?.onPick?.invoke(mode); true }
            }
    }

    /** The account picture: hold or slide to pick an account (only with more than one). */
    class Accounts(val onPick: (String) -> Unit) : TabHold() {
        override val isOpen get() = AccountTabPicker.menu.isOpen
        override val isPressed get() = AccountTabPicker.menu.isPressed
        override val shownName: String? get() = null
        override fun actions(current: () -> TabHold?) = AccountTabPicker.menu.listed.map { npub ->
            CustomAccessibilityAction("Switch to ${npub.take(12)}…") { (current() as? Accounts)?.onPick?.invoke(npub); true }
        }
    }
}

/** The hold-drag-release gesture on [hold]'s menu; a pick goes to the tab's latest hold ([current]). */
internal fun Modifier.tabHoldGesture(
    hold: TabHold,
    coordinates: () -> LayoutCoordinates?,
    view: View,
    onTap: () -> Unit,
    current: () -> TabHold?,
): Modifier = when (hold) {
    is TabHold.Feed -> dockHold(FeedTabPicker.menu, coordinates, view, onTap) { mode ->
        (current() as? TabHold.Feed)?.onPick?.invoke(mode)
    }
    is TabHold.Vault -> dockHold(VaultTabPicker.menu, coordinates, view, onTap) { mode ->
        (current() as? TabHold.Vault)?.onPick?.invoke(mode)
    }
    is TabHold.Accounts -> dockHold(AccountTabPicker.menu, coordinates, view, onTap) { npub ->
        (current() as? TabHold.Accounts)?.onPick?.invoke(npub)
    }
}
