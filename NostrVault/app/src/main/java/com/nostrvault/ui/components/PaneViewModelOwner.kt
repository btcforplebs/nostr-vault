package com.nostrvault.ui.components

import android.content.Context
import android.os.Bundle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.hilt.lifecycle.viewmodel.HiltViewModelFactory
import androidx.lifecycle.DEFAULT_ARGS_KEY
import androidx.lifecycle.HasDefaultViewModelProviderFactory
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewmodel.CreationExtras
import androidx.lifecycle.viewmodel.MutableCreationExtras
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.navigation.NavBackStackEntry

/**
 * Runs a screen that reads its arguments from saved state (`noteId`, `pubkey`)
 * inside a two-pane layout, where no route hands them over. [args] stand in for
 * the route's; the view models live in a store of their own that is cleared
 * when [key] changes or the pane leaves, so panes looked at earlier don't keep
 * running behind the open one.
 */
@Composable
internal fun PaneViewModelScope(key: Any, args: Bundle, content: @Composable () -> Unit) {
    val parent = checkNotNull(LocalViewModelStoreOwner.current)
    val context = LocalContext.current
    val owner = remember(parent, key) { PaneViewModelOwner(parent, args, context) }
    DisposableEffect(owner) {
        onDispose { owner.viewModelStore.clear() }
    }
    CompositionLocalProvider(LocalViewModelStoreOwner provides owner) { content() }
}

private class PaneViewModelOwner(
    parent: ViewModelStoreOwner,
    args: Bundle,
    context: Context,
) : ViewModelStoreOwner, HasDefaultViewModelProviderFactory {
    override val viewModelStore = ViewModelStore()

    private val parentDefaults = parent as? HasDefaultViewModelProviderFactory

    override val defaultViewModelProviderFactory: ViewModelProvider.Factory =
        if (parent is NavBackStackEntry) {
            HiltViewModelFactory(context, parent.defaultViewModelProviderFactory)
        } else {
            checkNotNull(parentDefaults) { "A pane needs a Hilt view model factory" }
                .defaultViewModelProviderFactory
        }

    override val defaultViewModelCreationExtras: CreationExtras =
        MutableCreationExtras(parentDefaults?.defaultViewModelCreationExtras ?: CreationExtras.Empty)
            .apply { set(DEFAULT_ARGS_KEY, args) }
}
