package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*

/**
 * One row of name chips for the active `@query`, docked just above the
 * toolbar like keyboard suggestions; swipe sideways for more. A tall list
 * here covered the line being typed (iOS ComposeView mention strip).
 */
@Composable
internal fun MentionSuggestions(
    results: List<FeedProfile>,
    onSelect: (FeedProfile) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        items(results) { profile ->
            Surface(
                onClick = { onSelect(profile) },
                color = Color(0xFF22222A),
                shape = RoundedCornerShape(50),
                modifier = Modifier
                    .height(44.dp)
                    .widthIn(max = 220.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(start = 6.dp, end = 14.dp),
                ) {
                    AvatarImage(
                        url = profile.pictureURL,
                        pubkey = profile.pubkey,
                        size = 30.dp,
                        displayName = profile.bestName,
                    )
                    Spacer(Modifier.width(8.dp))
                    Column {
                        Text(
                            text = profile.bestName,
                            color = PrimaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        profile.nip05?.takeIf { it.isNotBlank() }?.let { nip05 ->
                            Text(
                                text = nip05.removePrefix("_@"),
                                color = TertiaryText,
                                fontSize = 11.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}
