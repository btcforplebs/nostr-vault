package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/** The three key steps (setup screens r3). */
internal enum class KeyStepPart(val label: String) { KEY("Your key"), SPARE("Spare"), LOCK("Lock") }

/**
 * The key steps' header: Your key · Spare · Lock. Each part turns green once
 * done; the current one is orange. Twin of iOS KeyStepsStrip (#2416).
 */
@Composable
internal fun KeyStepsStrip(current: KeyStepPart) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.clearAndSetSemantics {
            contentDescription = "Step ${current.ordinal + 1} of 3: ${current.label}"
        },
    ) {
        KeyStepPart.entries.forEach { part ->
            val done = part.ordinal < current.ordinal
            val now = part == current
            val tint = when {
                done -> SuccessGreen
                now -> WizardAccent
                else -> WizardTextMuted
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .heightIn(min = 30.dp)
                    .clip(CircleShape)
                    .background(if (now) WizardAccent.copy(alpha = 0.12f) else WizardBgCard)
                    .border(1.dp, if (now) WizardBorderActive else WizardBorderSubtle, CircleShape)
                    .padding(horizontal = 10.dp),
            ) {
                Icon(
                    imageVector = if (done) Icons.Default.CheckCircle else when (part) {
                        KeyStepPart.KEY -> Icons.Default.Key
                        KeyStepPart.SPARE -> Icons.Default.ContentCopy
                        KeyStepPart.LOCK -> Icons.Default.Lock
                    },
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(part.label, color = tint, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            }
            if (part != KeyStepPart.LOCK) {
                Box(Modifier.width(10.dp).height(1.5.dp).background(if (done) SuccessGreen else WizardBorderSubtle))
            }
        }
    }
}
