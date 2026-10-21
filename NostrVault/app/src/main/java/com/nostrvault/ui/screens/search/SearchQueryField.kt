package com.nostrvault.ui.screens

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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PlaceholderText
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * The search box, drawn as iOS SearchView draws it: a filled grey field with
 * no border, radius 10, magnifying glass, and a clear (x) once there is text.
 * Return only hides the keyboard, as on the iPhone; typing already searches.
 */
@Composable
internal fun SearchQueryField(
    query: String,
    onQueryChange: (String) -> Unit,
    onClear: () -> Unit,
    onSubmit: () -> Unit,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    val placeholder = "Search users, notes, hashtags..."
    val focus = remember { FocusRequester() }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier
            .fillMaxWidth()
            // Fixed: the 48dp clear target must not make the box grow as text appears.
            .height(40.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(searchSecondary(0.1f))
            // A tap anywhere on the grey box puts the cursor in the field.
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { focus.requestFocus() }
            .padding(start = 12.dp, end = 4.dp),
    ) {
        Icon(NostrVaultIcons.Search, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(18.dp))
        BasicTextField(
            value = query,
            onValueChange = onQueryChange,
            singleLine = true,
            textStyle = TextStyle(color = PrimaryText, fontSize = 14.sp),
            cursorBrush = SolidColor(accent),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
            // TalkBack reads the field by its placeholder, as iOS reads the prompt.
            modifier = Modifier
                .weight(1f)
                .focusRequester(focus)
                .semantics { contentDescription = placeholder },
            decorationBox = { inner ->
                Box {
                    if (query.isEmpty()) Text(placeholder, color = PlaceholderText, fontSize = 14.sp, maxLines = 1)
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
                    .clickable(role = Role.Button, onClickLabel = "Clear", onClick = onClear)
                    .semantics { contentDescription = "Clear" },
            ) {
                Icon(Icons.Filled.Cancel, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(16.dp))
            }
        } else {
            Spacer(Modifier.width(8.dp))
        }
    }
}
