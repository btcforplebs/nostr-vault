package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * Edit the highlighted passage down to the part that matters and optionally
 * add a thought, which makes it a quote highlight. iOS HighlightSheet: a full
 * sheet with Cancel and Publish either side of its title.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HighlightSheet(
    initialPassage: String,
    onDismiss: () -> Unit,
    onPublish: (String, String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var passage by remember { mutableStateOf(initialPassage) }
    var comment by remember { mutableStateOf("") }
    val canPublish = passage.isNotBlank()
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = WindowBackground,
    ) {
        Column(modifier = Modifier.verticalScroll(rememberScrollState()).imePadding().padding(bottom = 24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
                TextButton(onClick = onDismiss) { Text("Cancel", color = colors.primary, fontSize = 16.sp) }
                Text(
                    "Highlight",
                    color = PrimaryText,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
                TextButton(onClick = { onPublish(passage, comment) }, enabled = canPublish) {
                    Text(
                        "Publish",
                        color = if (canPublish) colors.primary else SecondaryText,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            FormSection(header = "Highlight", footer = "Delete what you don't want to keep.") {
                FormField(passage, { passage = it }, placeholder = null, fontSize = 16, minHeight = 140)
            }
            FormSection(header = "Your thoughts (optional)", footer = null) {
                FormField(comment, { comment = it }, placeholder = "Add a comment", fontSize = 16, minHeight = 0, maxLines = 5)
            }
        }
    }
}

/** A grouped-form section: small header, rounded box, optional footer (SwiftUI Form Section). */
@Composable
private fun FormSection(header: String, footer: String?, content: @Composable () -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 16.dp).padding(top = 16.dp)) {
        Text(header, color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(start = 16.dp, bottom = 6.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(SecondaryGroupedBg)
                .padding(horizontal = 16.dp, vertical = 11.dp),
        ) { content() }
        footer?.let {
            Text(it, color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(start = 16.dp, top = 6.dp))
        }
    }
}

@Composable
private fun FormField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String?,
    fontSize: Int,
    minHeight: Int,
    maxLines: Int = Int.MAX_VALUE,
) {
    val colors = LocalNostrVaultColors.current
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        textStyle = TextStyle(color = PrimaryText, fontSize = fontSize.sp, lineHeight = (fontSize + 6).sp),
        cursorBrush = SolidColor(colors.primary),
        maxLines = maxLines,
        modifier = Modifier.fillMaxWidth().heightIn(min = minHeight.dp),
        decorationBox = { inner ->
            if (value.isEmpty() && placeholder != null) {
                Text(placeholder, color = TertiaryText, fontSize = fontSize.sp)
            }
            inner()
        },
    )
}
