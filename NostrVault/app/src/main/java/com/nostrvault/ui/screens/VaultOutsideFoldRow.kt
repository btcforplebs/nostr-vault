package com.nostrvault.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.VaultOutsideFold
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText

/**
 * All's one line for the likes and reposts from outside your web
 * ([VaultOutsideFold]): "N from outside your web", which opens the "Outside
 * your web" filter where they are listed. iOS `VaultOutsideFoldRow.swift`.
 */
@Composable
fun VaultOutsideFoldRow(count: Int, onOpen: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClickLabel = "Show likes and reposts from outside your web", onClick = onOpen)
            .padding(vertical = 10.dp),
    ) {
        Icon(NostrVaultIcons.OutsideNetwork, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Text(VaultOutsideFold.label(count), color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(14.dp))
    }
}
