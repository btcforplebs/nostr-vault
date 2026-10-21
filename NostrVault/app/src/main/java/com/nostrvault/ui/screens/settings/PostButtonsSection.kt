package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryText
import com.nostrvault.ui.theme.ZapOrange

/**
 * Appearance → Post buttons: the emoji the action bar under a post shows.
 * Adding ⚡️ puts a zap button on posts. Port of iOS `PostButtonsSection`
 * (AppearanceSettingsView): a text field, a preview of the bar, and the
 * same footer.
 */
@Composable
internal fun PostButtonsSection(value: String, onChange: (String) -> Unit) {
    val showsZap = HavenConfig.postButtonsShowZap(value)
    Column(modifier = Modifier.fillMaxWidth()) {
        Text("Post buttons", color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        CommitOnEndTextField(
            value = value,
            onCommit = onChange,
            label = { Text("Add ⚡️") },
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(12.dp))
        PostButtonsPreview(showsZap)
        Spacer(Modifier.height(8.dp))
        Text(
            "Add ⚡️ to show a zap button on posts. Zaps go straight from your own wallet " +
                "to the author over Nostr Wallet Connect. Profile zaps are always available.",
            color = TertiaryText,
            fontSize = 13.sp,
        )
    }
}

@Composable
private fun PostButtonsPreview(showsZap: Boolean) {
    val icons = listOf(NostrVaultIcons.ReplyAction, NostrVaultIcons.Repost, NostrVaultIcons.Quote, NostrVaultIcons.LikeOutline)
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.clearAndSetSemantics {
            contentDescription = if (showsZap) "Preview: reply, repost, quote, react, zap"
            else "Preview: reply, repost, quote, react"
        },
    ) {
        icons.forEach { PreviewCapsule(it, SecondaryText) }
        if (showsZap) PreviewCapsule(NostrVaultIcons.ZapOutline, ZapOrange)
    }
}

@Composable
private fun PreviewCapsule(icon: ImageVector, tint: Color) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(32.dp)
            .clip(CircleShape)
            .background(tint.copy(alpha = if (tint == ZapOrange) 0.2f else 0.1f)),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
    }
}
