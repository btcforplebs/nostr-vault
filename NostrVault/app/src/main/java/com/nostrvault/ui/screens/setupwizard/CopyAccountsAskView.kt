package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.fips.CopyAccounts
import com.nostrvault.fips.MeshPairing
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/** The ask's words and its tick rule, pure for the tests (Logen, 2026-11-06). */
object CopyAccountsAsk {
    const val TITLE = "Also bring these accounts?"
    const val MESSAGE = "These accounts came over with the copy. Tick the ones you want on this phone too. " +
        "They come look-only: just the public key, no private key or sign-in. Their notes are in this vault either way."
    const val BRING = "Bring them"
    const val JUST_THIS_ONE = "Just this one"

    /** [ticked] with [npub] switched. */
    fun toggle(ticked: Set<String>, npub: String): Set<String> = if (npub in ticked) ticked - npub else ticked + npub

    /** What [BRING] hands on: the ticked ones, in the list's order. [JUST_THIS_ONE] hands on none. */
    fun chosen(accounts: List<CopyAccounts.Account>, ticked: Set<String>): List<String> =
        accounts.map { it.npub }.filter { it in ticked }
}

/**
 * After a copy: "Also bring these accounts?" Lists the accounts the other vault brought over (name and short npub),
 * one checkbox each, nothing ticked to start, and hands on only the ticked ones ([onAnswer]; empty for
 * [CopyAccountsAsk.JUST_THIS_ONE]). Shown at the end of setup's copy, and as [CopyAccountsAskSheet] over the app when
 * a copy or catch-up finishes later. Twin of iOS `CopyAccountsAskView`.
 */
@Composable
internal fun CopyAccountsAskView(accounts: List<CopyAccounts.Account>, onAnswer: (List<String>) -> Unit) {
    var ticked by remember(accounts) { mutableStateOf(emptySet<String>()) }
    val chosen = CopyAccountsAsk.chosen(accounts, ticked)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.padding(20.dp),
    ) {
        Text(CopyAccountsAsk.TITLE, color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Text(CopyAccountsAsk.MESSAGE, color = SecondaryText, fontSize = 15.sp, lineHeight = 21.sp, textAlign = TextAlign.Center)
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.heightIn(max = 320.dp)) {
            items(accounts, key = { it.npub }) { a ->
                AccountRow(a, on = a.npub in ticked) { ticked = CopyAccountsAsk.toggle(ticked, a.npub) }
            }
        }
        WizardPrimaryButton(
            text = if (chosen.isEmpty()) CopyAccountsAsk.BRING else "${CopyAccountsAsk.BRING} (${chosen.size})",
            enabled = chosen.isNotEmpty(),
            onClick = { onAnswer(chosen) },
        )
        WizardSecondaryButton(text = CopyAccountsAsk.JUST_THIS_ONE, onClick = { onAnswer(emptyList()) })
    }
}

@Composable
private fun AccountRow(a: CopyAccounts.Account, on: Boolean, onToggle: () -> Unit) {
    val short = MeshPairing.shortAddress(a.npub)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .background(WizardBgCard, RoundedCornerShape(12.dp))
            .toggleable(value = on, role = Role.Checkbox, onValueChange = { onToggle() })
            .padding(12.dp)
            .testTag("copyAccounts.row"),
    ) {
        Checkbox(checked = on, onCheckedChange = null, colors = CheckboxDefaults.colors(checkedColor = WizardAccent))
        Column(Modifier.weight(1f)) {
            Text(a.name.ifEmpty { short }, color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (a.name.isNotEmpty()) Text(short, color = SecondaryText, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
        }
    }
}
