package com.nostrvault.ui.screens.settings

import android.text.format.DateUtils
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.DiscoveryReach
import com.nostrvault.service.DiscoveryReachStore
import com.nostrvault.ui.theme.*
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlin.math.roundToInt

@EntryPoint
@InstallIn(SingletonComponent::class)
interface DiscoveryReachEntryPoint {
    fun discoveryReachStore(): DiscoveryReachStore
    fun configStore(): com.nostrvault.data.local.ConfigStore
}

/**
 * Settings › Feed › Discovery Reach: the slider over the desktop Vault's
 * trust rank ([DiscoveryReach]). With no rank file it only says where scores
 * come from. iOS `DiscoveryReachSettingsSection.swift`.
 */
@Composable
fun DiscoveryReachSettingsSection() {
    val context = LocalContext.current
    val services = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, DiscoveryReachEntryPoint::class.java)
    }
    val store = services.discoveryReachStore()
    val copy by store.copy.collectAsState()
    val config by services.configStore().config.collectAsState()
    // The bar while the slider is held; saved when it is let go, so the feed is rebuilt once, not on every step.
    var dragging by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(Unit) { store.refresh() }

    Text(
        text = "Discovery Reach",
        color = SecondaryText,
        fontSize = 13.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(bottom = 8.dp),
    )
    Surface(shape = RoundedCornerShape(12.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
        val held = copy
        if (held == null) {
            Text(
                "Scores come from Nostr Vault on your desktop. Once it has ranked your network, this device gets the scores from it.",
                color = SecondaryText,
                fontSize = 13.sp,
                modifier = Modifier.padding(16.dp),
            )
            return@Surface
        }
        val bar = dragging ?: DiscoveryReach.bar(config.discoveryBar, held)
        val range = DiscoveryReach.range(held)
        Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Score", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
                Text("${bar.roundToInt()} and up", color = SecondaryText, fontSize = 15.sp)
            }
            Slider(
                value = bar.toFloat(),
                onValueChange = { dragging = it.roundToInt().toDouble() },
                onValueChangeFinished = {
                    dragging?.let { store.save(it) }
                    dragging = null
                },
                valueRange = range.start.toFloat()..range.endInclusive.toFloat(),
                steps = maxOf(0, (range.endInclusive - range.start).roundToInt() - 1),
                colors = SliderDefaults.colors(
                    thumbColor = LocalNostrVaultColors.current.primary,
                    activeTrackColor = LocalNostrVaultColors.current.primary,
                ),
            )
            Text(
                DiscoveryReach.countText(DiscoveryReach.count(held, bar)),
                color = SecondaryText,
                fontSize = 13.sp,
            )
        }
    }
    copy?.let {
        val ranked = DateUtils.getRelativeTimeSpanString(it.builtAt * 1000, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
        Text(
            text = "Underrated and Discover also show people your desktop Vault ranked at this score or higher. " +
                "Lower lets more in. Ranked $ranked.",
            color = TertiaryText,
            fontSize = 12.sp,
            modifier = Modifier.padding(start = 4.dp, top = 6.dp),
        )
    }
}
