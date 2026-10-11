package com.nostrvault.ui.components

import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlin.math.min

/**
 * The WOT tab's "Find someone": a way in for anyone who doesn't know where on
 * the globe a person is. Results show while there's text.
 */
@Composable
internal fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    onFocusChange: (Boolean) -> Unit,
    onSearch: () -> Unit,
    onClear: () -> Unit,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    BasicTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        textStyle = TextStyle(color = PrimaryText, fontSize = 15.sp),
        cursorBrush = SolidColor(accent),
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            imeAction = ImeAction.Search,
        ),
        keyboardActions = KeyboardActions(onSearch = { onSearch() }),
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .onFocusChanged { onFocusChange(it.isFocused) },
        decorationBox = { field ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color.White.copy(alpha = 0.08f))
                    .heightIn(min = 40.dp)
                    .padding(start = 12.dp, end = 4.dp),
            ) {
                Icon(NostrVaultIcons.Search, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(18.dp))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) Text("Find someone", color = SecondaryText, fontSize = 15.sp, maxLines = 1)
                    field()
                }
                if (query.isNotEmpty()) {
                    IconButton(onClick = onClear, modifier = Modifier.size(36.dp)) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Clear search", tint = SecondaryText,
                            modifier = Modifier.size(18.dp))
                    }
                }
            }
        },
    )
}
