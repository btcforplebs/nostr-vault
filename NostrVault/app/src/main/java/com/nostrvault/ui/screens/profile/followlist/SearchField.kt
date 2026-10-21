package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.remember
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PlaceholderText
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * The list's search box, drawn like the iOS search bar: a filled grey field,
 * no border, radius 10, and a clear (x) once there is text. Return hides the
 * keyboard; the list already filters as you type.
 */
@Composable
internal fun SearchField(query: String, placeholder: String, onChange: (String) -> Unit) {
    val colors = LocalNostrVaultColors.current
    val focusManager = LocalFocusManager.current
    val focus = remember { FocusRequester() }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            // Fixed: the 48dp clear target must not make the box grow as text appears.
            .height(38.dp)
            .clip(RoundedCornerShape(10.dp))
            // iOS Color.secondary.opacity(0.1): the secondary grey, faded further.
            .background(SecondaryText.copy(alpha = SecondaryText.alpha * 0.1f))
            // A tap anywhere on the grey box puts the cursor in the field.
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { focus.requestFocus() }
            .padding(start = 8.dp, end = 4.dp),
    ) {
        Icon(NostrVaultIcons.Search, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(18.dp))
        BasicTextField(
            value = query,
            onValueChange = onChange,
            singleLine = true,
            textStyle = TextStyle(color = PrimaryText, fontSize = 15.sp),
            cursorBrush = SolidColor(colors.primary),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { focusManager.clearFocus() }),
            // TalkBack reads the field by its placeholder, as iOS reads the prompt.
            modifier = Modifier
                .weight(1f)
                .focusRequester(focus)
                .semantics { contentDescription = placeholder },
            decorationBox = { inner ->
                Box {
                    if (query.isEmpty()) Text(placeholder, color = PlaceholderText, fontSize = 15.sp, maxLines = 1)
                    inner()
                }
            },
        )
        if (query.isNotEmpty()) {
            // xmark.circle.fill: drawn 16dp, tapped across 48dp.
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .minimumInteractiveComponentSize()
                    .clickable(role = Role.Button, onClickLabel = "Clear") { onChange("") }
                    .semantics { contentDescription = "Clear" },
            ) {
                Icon(Icons.Filled.Cancel, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(16.dp))
            }
        } else {
            Spacer(Modifier.width(4.dp))
        }
    }
}
