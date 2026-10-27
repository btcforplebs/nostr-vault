package com.nostrvault.ui.screens

import com.nostrvault.service.CustomEmoji

/** Custom emoji (NIP-30) in the composer: `:name` suggestions, inserting, and the post's tags. */

/** Every custom emoji the account can use: recents first, then its own emoji and sets. */
internal fun ComposeNoteViewModel.knownCustomEmoji(): List<CustomEmoji> {
    val state = emojiPalette.state.value
    val library = emojiList.library.value
    return (state.recents + state.slots).mapNotNull { it.custom } +
        library.single + library.sets.flatMap { it.emojis }
}

/** Finds the `:name` at the caret and fills [ComposeNoteViewModel.emojiSuggestions]. */
internal fun ComposeNoteViewModel.updateEmojiQuery(text: String, caret: Int) {
    val query = ComposeEmoji.queryAt(text, caret)
    emojiQuery = query
    _emojiSuggestions.value = if (query == null) emptyList() else ComposeEmoji.suggestions(query.text, knownCustomEmoji())
}

/** Replaces the active `:name` with [emoji]; returns the new (text, caret) for the editor. */
fun ComposeNoteViewModel.insertEmojiSuggestion(emoji: CustomEmoji): Pair<String, Int>? {
    val query = emojiQuery ?: return null
    val (text, caret) = ComposeEmoji.insert(content.value, query, emoji)
    emojiPalette.recordUse(com.nostrvault.data.local.ReactionPick.of(emoji))
    emojiQuery = null
    _emojiSuggestions.value = emptyList()
    onContentChanged(text, caret)
    return text to caret
}

/** Puts a picked emoji (Unicode or `:shortcode:`) in at [caret]; returns the new (text, caret). */
fun ComposeNoteViewModel.insertPickedEmoji(insertion: String, caret: Int): Pair<String, Int> {
    val (text, newCaret) = ComposeEmoji.insertAt(content.value, caret, insertion)
    onContentChanged(text, newCaret)
    return text to newCaret
}

/** The `emoji` tags for the custom emoji [content] uses (images the account knows). */
internal fun ComposeNoteViewModel.customEmojiTags(content: String): List<List<String>> {
    val known = LinkedHashMap<String, CustomEmoji>()
    for (emoji in knownCustomEmoji()) known.putIfAbsent(emoji.shortcode, emoji)
    return ComposeEmoji.tags(content, known)
}
