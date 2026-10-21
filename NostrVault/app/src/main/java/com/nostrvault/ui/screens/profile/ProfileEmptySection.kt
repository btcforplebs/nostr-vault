package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.SecondaryText

/**
 * Nothing in this note tab yet. It pages back on its own once the opening
 * load is in, and offers to look further when the automatic pages run out.
 * Port of iOS ProfileContent+Sections `emptyNoteSection`.
 */
@Composable
fun ProfileEmptySection(
    section: ProfileSection,
    opening: Boolean,
    pagingNow: Boolean,
    canPageOlder: Boolean,
    onAutoPage: () -> Unit,
    onLookFurther: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val status = ProfileEmptyTabPaging.status(opening, pagingNow, canPageOlder)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 48.dp),
    ) {
        Icon(
            section.icon,
            contentDescription = null,
            tint = SecondaryText.copy(alpha = 0.5f),
            modifier = Modifier.size(24.dp),
        )
        Text(
            text = when (status) {
                ProfileEmptyTabPaging.Status.LOADING -> "Loading…"
                ProfileEmptyTabPaging.Status.OLDER_LEFT -> "None in the latest posts"
                ProfileEmptyTabPaging.Status.NONE -> "No ${section.displayName.lowercase()} yet"
            },
            color = SecondaryText,
            fontSize = 12.sp,
        )
        when (status) {
            ProfileEmptyTabPaging.Status.LOADING ->
                CircularProgressIndicator(color = colors.primary, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            ProfileEmptyTabPaging.Status.OLDER_LEFT ->
                TextButton(onClick = onLookFurther) {
                    Text("Look further back", color = colors.primary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
            ProfileEmptyTabPaging.Status.NONE -> Unit
        }
    }
    // Again whenever a page finishes: it may have been another tab's.
    LaunchedEffect(section, opening, pagingNow) {
        if (!opening && !pagingNow) onAutoPage()
    }
}
