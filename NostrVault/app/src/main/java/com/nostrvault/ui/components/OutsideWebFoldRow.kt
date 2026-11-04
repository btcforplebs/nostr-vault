package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.TrustGate
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * The "Outside your web" fold under replies, comments and chat: how many
 * came from people outside your web of trust, and a Show/Hide to open them
 * ([TrustGate]). Twin of the iOS fold row.
 */
@Composable
fun OutsideWebFoldRow(
    count: Int,
    expanded: Boolean,
    accent: Color,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    noun: String = "reply",
    plural: String = "replies",
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClickLabel = if (expanded) "Hide" else "Show", onClick = onToggle)
            .semantics { stateDescription = if (expanded) "Shown" else "Folded" }
            .padding(horizontal = 16.dp, vertical = 14.dp)
            .testTag("trust.outsideFold"),
    ) {
        Column(Modifier.weight(1f)) {
            Text(TrustGate.OUTSIDE_TITLE, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Text(TrustGate.foldLabel(count, noun, plural), color = SecondaryText, fontSize = 12.sp)
        }
        Spacer(Modifier.width(12.dp))
        Text(if (expanded) "Hide" else "Show", color = accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}
