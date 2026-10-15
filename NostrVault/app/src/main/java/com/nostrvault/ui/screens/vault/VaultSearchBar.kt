package com.nostrvault.ui.screens.vault

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface2
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The bar's height; closed, it is a circle this wide on the trailing edge. */
private val BAR_HEIGHT = 40.dp

/**
 * The Vault's search field (iOS `VaultSearchBar`). It opens out of the
 * magnifying glass at the top right: a circle on the trailing edge that widens
 * into the bar, then the field fades in. The ✕ where the icon was folds it back
 * into the circle before [onClose] runs, so the icon is what's left when it goes.
 * Laid out at full width from the start; only the background and its clip move.
 */
@Composable
internal fun VaultSearchBar(
    text: String,
    onTextChange: (String) -> Unit,
    onSubmit: () -> Unit,
    /** Runs once the bar has folded back into the icon. */
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val progress = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    val focus = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val accent = LocalNostrVaultColors.current.primary
    LaunchedEffect(Unit) {
        if (Motion.isReduced) progress.snapTo(1f) else progress.animateTo(1f, Motion.panel())
    }
    // Focus once the field is mostly in: focusing at once raises the keyboard
    // over a bar that is still a circle.
    LaunchedEffect(Unit) {
        delay(180)
        runCatching { focus.requestFocus() }
    }
    val close: () -> Unit = {
        focusManager.clearFocus()
        keyboard?.hide()
        scope.launch {
            if (Motion.isReduced) progress.snapTo(0f) else progress.animateTo(0f, Motion.panel())
            onClose()
        }
    }

    BoxWithConstraints(modifier.fillMaxWidth().height(BAR_HEIGHT)) {
        val p = progress.value
        val width = BAR_HEIGHT + (maxWidth - BAR_HEIGHT) * p
        // The glass grows from the icon's circle on the trailing edge.
        Box(
            Modifier
                .align(Alignment.CenterEnd)
                .width(width)
                .fillMaxHeight()
                .background(Surface2, CircleShape)
                .border(0.8.dp, Color.White.copy(alpha = 0.12f), CircleShape),
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp),
        ) {
            Box(Modifier.weight(1f).alpha(p)) {
                if (text.isEmpty()) Text("Search your Vault", color = SecondaryText, fontSize = 16.sp)
                BasicTextField(
                    value = text,
                    onValueChange = onTextChange,
                    singleLine = true,
                    textStyle = TextStyle(color = PrimaryText, fontSize = 16.sp),
                    cursorBrush = SolidColor(accent),
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.None,
                        autoCorrectEnabled = false,
                        imeAction = ImeAction.Search,
                    ),
                    keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(focus)
                        .semantics { contentDescription = "Search your Vault" },
                )
            }
            if (text.isNotEmpty()) {
                IconButton(onClick = { onTextChange("") }, modifier = Modifier.size(28.dp).alpha(p)) {
                    Icon(NostrVaultIcons.Dismiss, contentDescription = "Clear search", tint = SecondaryText,
                        modifier = Modifier.size(16.dp))
                }
            }
            // Where the toolbar's magnifying glass was: open, the same spot is the
            // ✕ that folds the bar back into it.
            IconButton(onClick = close, modifier = Modifier.size(BAR_HEIGHT)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(NostrVaultIcons.Search, contentDescription = null, tint = accent,
                        modifier = Modifier.size(18.dp).alpha(1 - p))
                    Icon(NostrVaultIcons.Dismiss, contentDescription = "Close search", tint = accent,
                        modifier = Modifier.size(18.dp).alpha(p))
                }
            }
        }
    }
}
