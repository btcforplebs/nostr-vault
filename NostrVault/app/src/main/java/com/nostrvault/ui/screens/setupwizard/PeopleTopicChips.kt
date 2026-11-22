package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * The people step's topic chips: the hashtags the offered people share
 * ([com.nostrvault.setup.ReferrerFollows.topics]). Tapping one shows only
 * the people who use it; tapping it again, or All, shows everyone. Scrolls
 * sideways when the chips don't fit. Twin of iOS PeopleTopicChips (#2414).
 */
@Composable
internal fun PeopleTopicChips(topics: List<String>, selected: String?, onPick: (String?) -> Unit) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 2.dp),
    ) {
        TopicChip("All", on = selected == null, description = "All topics") { onPick(null) }
        topics.forEach { topic ->
            TopicChip("#$topic", on = selected == topic, description = "Topic $topic") { onPick(topic) }
        }
    }
}

@Composable
private fun TopicChip(label: String, on: Boolean, description: String, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .heightIn(min = 36.dp)
            .clip(CircleShape)
            .then(if (on) Modifier.background(WizardGradient) else Modifier.background(WizardBgCard))
            .border(1.dp, if (on) Color.Transparent else WizardBorderSubtle, CircleShape)
            .clickable(onClick = onClick)
            .semantics { contentDescription = description; selected = on }
            .padding(horizontal = 14.dp),
    ) {
        Text(label, color = if (on) Color.White else PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}
