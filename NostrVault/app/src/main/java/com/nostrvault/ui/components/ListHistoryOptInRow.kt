package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.ListHistoryScan
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * Moving in's choice to look up older versions of the owner's lists on the
 * Lazarus history relays and keep them ([ListHistoryScan]). On by default
 * ([ListHistoryScan.DEFAULT_ON]); off skips every history relay. The caller
 * passes it to [com.nostrvault.service.RelayImportService.importNotes]. Used
 * by the setup wizard's relay check and the Vault Dashboard's Moving in. Twin
 * of iOS `ListHistoryOptInToggle.swift`.
 */
@Composable
fun ListHistoryOptInRow(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    textColor: Color = SecondaryText,
    titleColor: Color = PrimaryText,
    accent: Color = Color(0xFFE67326),
) {
    Column(modifier = modifier.fillMaxWidth().testTag("import.listHistory.optIn")) {
        // Only the title and switch toggle, so a tap on the link below opens Lazarus and nothing else.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange),
        ) {
            Text(ListHistoryScan.OPT_IN_TITLE, color = titleColor, fontSize = 15.sp, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(12.dp))
            Switch(
                checked = checked,
                onCheckedChange = null,
                colors = SwitchDefaults.colors(checkedTrackColor = accent),
            )
        }
        Text(
            lazarusNote(accent),
            color = textColor,
            fontSize = 12.sp,
            lineHeight = 16.sp,
            modifier = Modifier.testTag("import.listHistory.note"),
        )
    }
}

/** [ListHistoryScan.OPT_IN_NOTE] with its "Lazarus" as a link to the project, opened in the browser. */
internal fun lazarusNote(linkColor: Color): AnnotatedString = buildAnnotatedString {
    val note = ListHistoryScan.OPT_IN_NOTE
    val word = ListHistoryScan.LAZARUS_WORD
    val at = note.indexOf(word)
    if (at < 0) {
        append(note)
        return@buildAnnotatedString
    }
    append(note.substring(0, at))
    val style = TextLinkStyles(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline))
    withLink(LinkAnnotation.Url(ListHistoryScan.LAZARUS_URL, style)) { append(word) }
    append(note.substring(at + word.length))
}
