package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.InterestList
import com.nostrvault.ui.theme.SecondaryText

/**
 * Follow many hashtags at once from the Hashtags feed: type or paste
 * "#bitcoin #nostr art", tap Add, and they all go into one published list.
 * Pieces that can't be a hashtag stay in the field, with a note saying so.
 * iOS: AddHashtagsField.
 */
@Composable
internal fun AddHashtagsField(onAdd: (String) -> InterestList.Parsed) {
    var text by rememberSaveable { mutableStateOf("") }
    var note by rememberSaveable { mutableStateOf<String?>(null) }
    fun add() {
        if (text.isBlank()) return
        val parsed = onAdd(text)
        text = parsed.rejected.joinToString(" ")
        note = when {
            parsed.rejected.isEmpty() -> null
            parsed.rejected.size == 1 -> "\"${parsed.rejected[0]}\" isn't a hashtag: use letters, numbers or _."
            else -> "These aren't hashtags: use letters, numbers or _."
        }
    }
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                value = text,
                onValueChange = {
                    text = it
                    note = null
                },
                placeholder = { Text("Add hashtags: #art #music…") },
                maxLines = 3,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                    imeAction = ImeAction.Done,
                ),
                keyboardActions = KeyboardActions(onDone = { add() }),
                modifier = Modifier.weight(1f),
            )
            Button(onClick = { add() }, enabled = text.isNotBlank()) { Text("Add") }
        }
        note?.let {
            Text(it, color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))
        }
    }
}
