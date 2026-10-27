package com.nostrvault.ui.screens.dm

import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.content.MediaType
import androidx.compose.foundation.content.consume
import androidx.compose.foundation.content.contentReceiver
import androidx.compose.foundation.content.hasMediaType
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PlaceholderText
import com.nostrvault.ui.theme.SeparatorColor
import com.nostrvault.ui.components.ProseKeyboardOptions

/**
 * The thread's message box: the outlined field it always was, built on the
 * state-based text field because only that one takes a photo. Paste from the
 * text menu or the keyboard's clipboard, a keyboard image or a photo dropped
 * on it hands the photo to [onPasteImage] (iOS PastesClipboardImage, #348);
 * text in the same paste still goes in as text.
 */
@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterial3Api::class)
@Composable
internal fun DMMessageField(
    state: TextFieldState,
    onPasteImage: (Uri) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val interactionSource = remember { MutableInteractionSource() }
    val fieldColors = OutlinedTextFieldDefaults.colors(
        focusedBorderColor = colors.primary,
        unfocusedBorderColor = SeparatorColor,
        cursorColor = colors.primary,
    )
    val shape = RoundedCornerShape(20.dp)

    BasicTextField(
        state = state,
        modifier = modifier
            .defaultMinSize(minHeight = OutlinedTextFieldDefaults.MinHeight)
            .contentReceiver { content ->
                if (!content.hasMediaType(MediaType.Image)) return@contentReceiver content
                // One photo per message, as the picker: the first one wins.
                var photo: Uri? = null
                val rest = content.consume { item ->
                    val uri = item.uri ?: return@consume false
                    if (photo == null) photo = uri
                    true
                }
                photo?.let(onPasteImage)
                rest
            },
        textStyle = LocalTextStyle.current.merge(TextStyle(color = MaterialTheme.colorScheme.onSurface)),
        keyboardOptions = ProseKeyboardOptions,
        cursorBrush = SolidColor(colors.primary),
        lineLimits = TextFieldLineLimits.MultiLine(maxHeightInLines = 5),
        interactionSource = interactionSource,
        decorator = { innerTextField ->
            OutlinedTextFieldDefaults.DecorationBox(
                value = state.text.toString(),
                innerTextField = innerTextField,
                enabled = true,
                singleLine = false,
                visualTransformation = VisualTransformation.None,
                interactionSource = interactionSource,
                placeholder = { Text("Message...", color = PlaceholderText) },
                colors = fieldColors,
                container = {
                    OutlinedTextFieldDefaults.ContainerBox(
                        enabled = true,
                        isError = false,
                        interactionSource = interactionSource,
                        colors = fieldColors,
                        shape = shape,
                    )
                },
            )
        },
    )
}
