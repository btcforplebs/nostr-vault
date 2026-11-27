package com.nostrvault.ui.screens.vault

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.Ink
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.OnAccent
import com.nostrvault.ui.theme.PrimaryText

/** Where the Vault search's "Notes / My notes" switch is remembered, so it opens as it was left. */
internal object VaultSearchScope {
    private const val PREFS = "vault_search"
    private const val KEY_MINE_ONLY = "my_notes"

    fun load(context: Context): Boolean =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_MINE_ONLY, false)

    fun save(context: Context, mineOnly: Boolean) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_MINE_ONLY, mineOnly).apply()
    }
}

/**
 * The Vault search's scope switch (iOS twin: the Notes / My notes picker in
 * `VaultSearchResults`): Notes searches everything in the Vault; My notes only
 * what the account in use wrote, with no People.
 */
@Composable
internal fun VaultSearchScopeToggle(
    mineOnly: Boolean,
    onChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        modifier = modifier
            .fillMaxWidth()
            .height(34.dp)
            .background(Ink.copy(alpha = 0.10f), CircleShape)
            .padding(2.dp),
    ) {
        Segment("Notes", isOn = !mineOnly, modifier = Modifier.weight(1f)) { onChange(false) }
        Segment("My notes", isOn = mineOnly, modifier = Modifier.weight(1f)) { onChange(true) }
    }
}

@Composable
private fun Segment(title: String, isOn: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val accent = LocalNostrVaultColors.current.primary
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(30.dp)
            .background(if (isOn) accent else Ink.copy(alpha = 0f), CircleShape)
            .clickable(onClick = onClick)
            .semantics {
                selected = isOn
                role = Role.Tab
            },
    ) {
        Text(title, color = if (isOn) OnAccent else PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}
