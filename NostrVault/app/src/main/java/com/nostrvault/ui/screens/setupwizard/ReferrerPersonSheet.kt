package com.nostrvault.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.setup.ReferrerFollows
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*

/**
 * A person from "<Name>'s people", tapped: who they are (photo, name,
 * NIP-05, about) and how they and the referrer are linked, with Follow.
 * Follow only picks them for the end of setup, like the row's pill; nothing
 * is signed until setup has the key (Logen 2026-11-22: people choose,
 * instead of ticking strangers).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ReferrerPersonSheet(
    pick: ReferrerFollows.Pick,
    profile: FeedProfile?,
    name: String,
    relation: String,
    following: Boolean,
    onToggle: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = WizardBgPrimary,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 28.dp),
        ) {
            AvatarImage(url = profile?.pictureURL, pubkey = pick.pubkey, size = 88.dp, displayName = profile?.bestName)
            Spacer(Modifier.height(12.dp))
            Text(name, color = PrimaryText, fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            profile?.nip05?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.height(8.dp))
            Text(relation, color = WizardAccent, fontSize = 14.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center)
            profile?.about?.takeIf { it.isNotBlank() }?.let {
                Spacer(Modifier.height(14.dp))
                Text(
                    it,
                    color = SecondaryText,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                    textAlign = TextAlign.Center,
                    maxLines = 8,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.height(22.dp))
            if (following) {
                OutlinedButton(
                    onClick = onToggle,
                    border = BorderStroke(1.dp, WizardBorderActive),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                ) { Text("Following", color = WizardAccent, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) }
            } else {
                WizardPrimaryButton(text = "Follow", onClick = onToggle)
            }
        }
    }
}

/** A row's Follow / Following pill in "<Name>'s people". */
@Composable
internal fun ReferrerFollowPill(following: Boolean, onClick: () -> Unit) {
    if (following) {
        OutlinedButton(
            onClick = onClick,
            border = BorderStroke(1.dp, WizardBorderActive),
            contentPadding = PaddingValues(horizontal = 14.dp),
            modifier = Modifier.heightIn(min = 36.dp),
        ) { Text("Following", color = WizardAccent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
    } else {
        Button(
            onClick = onClick,
            colors = ButtonDefaults.buttonColors(containerColor = WizardAccent, contentColor = WizardBgPrimary),
            contentPadding = PaddingValues(horizontal = 14.dp),
            modifier = Modifier.heightIn(min = 36.dp),
        ) { Text("Follow", fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
    }
}
