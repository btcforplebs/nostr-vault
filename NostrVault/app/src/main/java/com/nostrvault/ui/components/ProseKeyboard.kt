package com.nostrvault.ui.components

import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardCapitalization

/**
 * Keyboard for text people write as sentences: notes, replies, DMs, chat, bios.
 * Keys, npubs, relay URLs, NWC strings, search and hashtags keep the default.
 */
val ProseKeyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences)
