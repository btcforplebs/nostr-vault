package com.nostrvault.ui.components

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.nostrvault.data.model.TrustMapOuter
import com.nostrvault.ui.screens.pairing.PairDeviceScreen
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Whether "Not now" put the globe's desktop Vault invite away. Only Settings › Feed › Discovery Reach brings it back. */
internal object HavenInviteSetting {
    private const val PREFS = "globe_outer_rings"
    private val hiddenFlow = MutableStateFlow<Boolean?>(null)

    fun hidden(context: Context): StateFlow<Boolean?> {
        if (hiddenFlow.value == null) hiddenFlow.value = prefs(context).getBoolean(TrustMapOuter.INVITE_HIDDEN_KEY, false)
        return hiddenFlow.asStateFlow()
    }

    fun setHidden(context: Context, hidden: Boolean) {
        prefs(context).edit().putBoolean(TrustMapOuter.INVITE_HIDDEN_KEY, hidden).apply()
        hiddenFlow.value = hidden
    }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/**
 * On your own globe with no desktop Vault paired: the faint outer rings'
 * invite. "Pair a desktop Vault" opens Add a device; "Not now" puts it away.
 * Never says "Haven" (Logen 2026-11-22). iOS `Views/TrustWeb/HavenInviteCard.swift`.
 */
@Composable
internal fun HavenInviteCard(accent: Color, onNotNow: () -> Unit, modifier: Modifier = Modifier) {
    var pairing by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(16.dp)
    Column(
        modifier
            .widthIn(max = 420.dp)
            .fillMaxWidth()
            .background(Color(0xE61C1C22), shape)
            .border(1.dp, Color.White.copy(alpha = 0.14f), shape)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("There's more out here", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "${TrustMapOuter.PAIR_LINE}. Your desktop Vault ranks people three or more hops out and sends the scores to this device.",
            color = Color.White.copy(alpha = 0.65f), fontSize = 13.sp,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = { pairing = true },
                colors = ButtonDefaults.buttonColors(containerColor = accent, contentColor = Color.White),
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp),
            ) { Text("Pair a desktop Vault", fontSize = 13.sp) }
            OutlinedButton(
                onClick = onNotNow,
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp),
            ) { Text("Not now", color = accent, fontSize = 13.sp) }
        }
    }
    if (pairing) {
        Dialog(onDismissRequest = { pairing = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            PairDeviceScreen(onBack = { pairing = false })
        }
    }
}
