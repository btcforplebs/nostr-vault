package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.TextFieldColors
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction

/**
 * A text field that hands its value to [onCommit] only when editing ends:
 * the keyboard's Done key, focus leaving, or the screen closing. For settings
 * the relay reads at start, where every saved half-typed value (2, 20, 202…)
 * would otherwise be a relay-facing save. Port of iOS CommitOnEndTextField
 * (#92, #97): an edit still open when the user leaves the screen is saved.
 */
@Composable
fun CommitOnEndTextField(
    value: String,
    onCommit: (String) -> Unit,
    modifier: Modifier = Modifier,
    label: @Composable (() -> Unit)? = null,
    colors: TextFieldColors = OutlinedTextFieldDefaults.colors(),
) {
    var draft by remember { mutableStateOf(value) }
    var focused by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current

    // Follow outside changes while the user isn't typing.
    LaunchedEffect(value) { if (!focused) draft = value }

    val latestDraft by rememberUpdatedState(draft)
    val latestValue by rememberUpdatedState(value)
    val latestOnCommit by rememberUpdatedState(onCommit)
    fun commit() {
        if (latestDraft != latestValue) latestOnCommit(latestDraft)
    }
    DisposableEffect(Unit) {
        onDispose { commit() }
    }

    OutlinedTextField(
        value = draft,
        onValueChange = { draft = it },
        label = label,
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
        colors = colors,
        modifier = modifier.onFocusChanged { state ->
            if (focused && !state.isFocused) commit()
            focused = state.isFocused
        },
    )
}
