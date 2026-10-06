package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.FeedLanguage
import com.nostrvault.service.NoteTranslationPolicy
import com.nostrvault.service.NoteTranslator
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * What a note card needs to offer "Translate": the on-device translator, the
 * Appearance > Translation switch, and the resolved target language. Null
 * (the default) means no translation, e.g. in previews.
 */
class NoteTranslationContext(
    val translator: NoteTranslator,
    val enabled: Boolean,
    val target: String,
)

val LocalNoteTranslation = staticCompositionLocalOf<NoteTranslationContext?> { null }

/** The device's languages as BCP-47 tags, most preferred first. */
fun deviceLanguageTags(): List<String> {
    val locales = android.os.LocaleList.getDefault()
    return (0 until locales.size()).map { locales[it].toLanguageTag() }
}

private enum class TranslateState { IDLE, DOWNLOADING, TRANSLATING, FAILED }

/**
 * A note's text with a small "Translate" button under it when the note is in
 * a language other than the user's target. Tapping translates on device and
 * swaps the text for the translation, with "Show original" to swap back.
 *
 * [original] draws the untranslated text (the rich renderer); the
 * translation itself is plain text, mentions resolved to @names.
 */
@Composable
fun TranslatableNoteText(
    noteKey: String,
    content: String,
    profiles: Map<String, FeedProfile>,
    mediaURLs: Set<String>,
    linkURLs: Set<String>,
    fontSize: TextUnit,
    lineHeight: TextUnit,
    modifier: Modifier = Modifier,
    onTranslationClick: (() -> Unit)? = null,
    /** Lets the translation be selected, as the note detail's original is. */
    selectable: Boolean = false,
    original: @Composable () -> Unit,
) {
    val context = LocalNoteTranslation.current
    val enoughText = remember(content) { NoteTranslationPolicy.hasEnoughText(content) }
    if (context == null || !context.enabled || !enoughText) {
        Column(modifier) { original() }
        return
    }
    val translator = context.translator
    val target = context.target

    var source by remember(noteKey) { mutableStateOf(translator.cachedLanguage(noteKey)) }
    LaunchedEffect(noteKey) {
        if (!translator.isIdentified(noteKey)) {
            source = translator.identify(noteKey, NoteTranslationPolicy.languageText(content))
        }
    }

    var translation by remember(noteKey, target) { mutableStateOf(translator.cachedTranslation(noteKey, target)) }
    var showTranslation by remember(noteKey, target) { mutableStateOf(false) }
    var state by remember(noteKey, target) { mutableStateOf(TranslateState.IDLE) }
    val scope = rememberCoroutineScope()

    val from = source
    val offer = NoteTranslationPolicy.shouldOffer(context.enabled, content, from, target)

    Column(modifier) {
        val shown = translation
        if (offer && showTranslation && shown != null) {
            val translated = @Composable {
                Text(
                    text = shown,
                    color = PrimaryText,
                    fontSize = fontSize,
                    lineHeight = lineHeight,
                    modifier = if (onTranslationClick != null) Modifier.clickable(onClick = onTranslationClick) else Modifier,
                )
            }
            if (selectable) SelectionContainer { translated() } else translated()
        } else {
            original()
        }

        if (!offer || from == null) return@Column

        val label = when {
            showTranslation && shown != null ->
                "Translated from ${FeedLanguage(from).displayName()} · Show original"
            state == TranslateState.DOWNLOADING -> "Downloading language…"
            state == TranslateState.TRANSLATING -> "Translating…"
            state == TranslateState.FAILED -> "Couldn't translate · Retry"
            else -> "Translate"
        }
        val busy = state == TranslateState.DOWNLOADING || state == TranslateState.TRANSLATING
        Row(modifier = Modifier.padding(top = 4.dp)) {
            Text(
                text = label,
                color = SecondaryText,
                fontSize = 13.sp,
                modifier = Modifier
                    .clickable(enabled = !busy) {
                        when {
                            showTranslation -> showTranslation = false
                            translation != null -> showTranslation = true
                            else -> scope.launch {
                                state = if (translator.needsDownload(from, target)) {
                                    TranslateState.DOWNLOADING
                                } else {
                                    TranslateState.TRANSLATING
                                }
                                try {
                                    val plain = NostrMentions.toPlainText(content, profiles, mediaURLs, linkURLs)
                                    translation = translator.translate(noteKey, plain, from, target)
                                    showTranslation = true
                                    state = TranslateState.IDLE
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (_: Exception) {
                                    state = TranslateState.FAILED
                                }
                            }
                        }
                    }
                    .padding(vertical = 2.dp),
            )
        }
    }
}
