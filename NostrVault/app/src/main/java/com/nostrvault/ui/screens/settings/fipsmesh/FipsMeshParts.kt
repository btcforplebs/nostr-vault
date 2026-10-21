package com.nostrvault.ui.screens.settings.fipsmesh

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.fips.DeviceRole
import com.nostrvault.ui.theme.CardBackground
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SeparatorColor
import com.nostrvault.ui.theme.SuccessGreen

// The grouped-list pieces the FIPS Mesh pages share: a titled card, its rows and the footnote under it, laid out as
// the iPhone's inset grouped list (OUTBOX/NV_FIPS_SETTINGS).

@Composable
internal fun MeshSection(title: String?, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = 20.dp)) {
        title?.let {
            Text(it.uppercase(), color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp,
                modifier = Modifier.padding(start = 4.dp, bottom = 8.dp))
        }
        Surface(color = CardBackground, shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(horizontal = 14.dp), content = content)
        }
        footer?.let { MeshFooter(it) }
    }
}

@Composable
internal fun MeshFooter(text: String, color: Color = SecondaryText) {
    Text(text, color = color, fontSize = 13.sp, lineHeight = 18.sp, modifier = Modifier.padding(start = 4.dp, end = 4.dp, top = 8.dp))
}

@Composable
internal fun MeshDivider() = HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

@Composable
internal fun MeshSwitchRow(title: String, subtitle: String?, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    val colors = LocalNostrVaultColors.current
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
        Column(Modifier.weight(1f)) {
            Text(title, color = PrimaryText, fontSize = 16.sp)
            subtitle?.let { Text(it, color = SecondaryText, fontSize = 13.sp, lineHeight = 18.sp) }
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled,
            colors = SwitchDefaults.colors(checkedTrackColor = colors.primary))
    }
}

/** A row with a value on the right; tappable when [onClick] is set (a picker, or a page with a chevron). */
@Composable
internal fun MeshValueRow(title: String, value: String, chevron: Boolean = false, onClick: (() -> Unit)? = null) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().let { if (onClick != null) it.clickable(onClick = onClick) else it }.padding(vertical = 14.dp),
    ) {
        Text(title, color = PrimaryText, fontSize = 16.sp, modifier = Modifier.weight(1f))
        Text(value, color = SecondaryText, fontSize = 14.sp, maxLines = 1)
        if (chevron) Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(20.dp))
    }
}

/** A coloured dot and a short line: "On · 3 of 4 devices in reach", "In reach", "2 h ago". */
@Composable
internal fun StatusDot(text: String, on: Boolean, modifier: Modifier = Modifier) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = modifier) {
        Box(Modifier.size(8.dp).background(if (on) SuccessGreen else SecondaryText, CircleShape))
        Text(text, color = SecondaryText, fontSize = 13.sp)
    }
}

internal val DeviceRole.icon: ImageVector get() = when (this) {
    DeviceRole.MAC -> Icons.Filled.Computer
    DeviceRole.PHONE -> Icons.Filled.PhoneAndroid
    DeviceRole.HOME_VAULT -> Icons.Filled.Home
    DeviceRole.BROWSER -> Icons.Filled.Language
}

/** The role's tile: a white glyph on the teal square the iPhone list uses. */
@Composable
internal fun RoleTile(role: DeviceRole) {
    Box(Modifier.size(32.dp).background(Color(0xFF00C7D9), RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
        Icon(role.icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
    }
}

/** "1 GB", "250 MB". */
internal fun bytesLabel(bytes: Long): String {
    val mb = bytes shr 20
    return if (mb >= 1024 && mb % 1024 == 0L) "${mb / 1024} GB" else if (mb >= 1) "$mb MB" else "$bytes B"
}

/** The limits offered for one sharing session, as in the iOS kiosk picker. */
internal val SERVE_LIMITS = listOf(250L shl 20, 1L shl 30, 5L shl 30)
