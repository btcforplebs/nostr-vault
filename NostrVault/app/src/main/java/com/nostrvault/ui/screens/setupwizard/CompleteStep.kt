package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CellTower
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

// ══════════════════════════════════════════════════════════════════
// Step 8: Complete
// ══════════════════════════════════════════════════════════════════

@Composable
internal fun CompleteStep(
    setupPath: SetupPath,
    /** "I already use Nostr" with only a public key. */
    readOnly: Boolean,
    onFinish: () -> Unit,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        WizardCard {
            Text(
                text = when (setupPath) {
                    SetupPath.NEW_TO_NOSTR -> "Welcome to Nostr!"
                    else -> "You're all set!"
                },
                color = WizardAccent,
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(16.dp))

            when (setupPath) {
                SetupPath.NEW_TO_NOSTR -> {
                    WizardCheckItem("Account created")
                    WizardCheckItem("Relay is running")
                    Spacer(Modifier.height(16.dp))
                    // How the on-device relay and Blossom reach everyone else.
                    Column(
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(WizardBgElevated)
                            .border(1.dp, WizardBorderSubtle, RoundedCornerShape(12.dp))
                            .padding(16.dp),
                    ) {
                        CompleteExplainerRow(
                            Icons.Default.CellTower,
                            "Your relay lives on this phone and sends your posts out to public relays so people can see them.",
                        )
                        CompleteExplainerRow(
                            Icons.Default.PhotoLibrary,
                            "Blossom does the same for photos and videos: they're kept here and copied to public media servers.",
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = "Next, a short guide helps you find people to follow.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                }
                SetupPath.USE_NOSTR -> {
                    WizardCheckItem(if (readOnly) "Connected to Nostr" else "Signed in")
                    WizardCheckItem("Using your relay")
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = if (readOnly) "Read-only for now. Add your private key in Settings to post."
                        else "Your posts go out through the relay you chose.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                }
                SetupPath.BROWSE -> {
                    WizardCheckItem("Connected to Nostr")
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = "You're in browse mode. Upgrade to full setup for signing, your own relay, and media storage.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                }
                else -> {
                    WizardCheckItem("Relay is running")
                    WizardCheckItem("DMs enabled")
                    WizardCheckItem("Blossom media active")
                    WizardCheckItem("Posts being broadcast")
                }
            }
        }

        Spacer(Modifier.height(32.dp))
        WizardPrimaryButton(
            text = when (setupPath) {
                SetupPath.NEW_TO_NOSTR -> "Start Exploring"
                else -> "Open Nostr Vault"
            },
            onClick = onFinish,
        )
    }
}

@Composable
private fun CompleteExplainerRow(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Text(text, color = SecondaryText, fontSize = 13.sp, lineHeight = 18.sp)
    }
}

@Composable
private fun WizardCheckItem(text: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Check,
            contentDescription = null,
            tint = SuccessGreen,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(10.dp))
        Text(text, color = PrimaryText, fontSize = 15.sp)
    }
}
