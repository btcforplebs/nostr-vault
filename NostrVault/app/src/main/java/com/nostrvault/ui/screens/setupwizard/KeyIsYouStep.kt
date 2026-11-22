package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

// ══════════════════════════════════════════════════════════════════
// Step: This key is you (New to Nostr path)
// ══════════════════════════════════════════════════════════════════

/**
 * The first key step (setup screens r3, Way 1a): your photo and name, "=",
 * and the key. The key was made when Create an account was picked; the
 * secret stays masked until Show. Keeping a spare is the next step
 * (KeySpareStep), the password the one after (KeyPasswordStep). Twin of iOS
 * KeyIsYouStep (#2416).
 */
@Composable
internal fun KeyIsYouStep(viewModel: SetupWizardViewModel) {
    val generatedNsec by viewModel.generatedNsec.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val name by viewModel.profileName.collectAsState()
    val photo by viewModel.profilePhotoJpeg.collectAsState()
    var shown by remember { mutableStateOf(false) }
    // The nsec can be shown here: keep it out of screenshots and Recents.
    com.nostrvault.ui.components.SecureWindowEffect()

    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Spacer(Modifier.height(8.dp))
        KeyStepsStrip(KeyStepPart.KEY)
        Spacer(Modifier.height(22.dp))
        Text(
            "This key is you",
            color = PrimaryText,
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(Modifier.height(22.dp))
        YouEqualsKey(displayName(name), photo)
        Spacer(Modifier.height(22.dp))

        val nsec = generatedNsec
        if (nsec == null) {
            // Only seen if making the key failed when Create an account was picked.
            error?.let {
                Text(it, color = Color(0xFFEF4444), fontSize = 14.sp)
                Spacer(Modifier.height(8.dp))
            }
            WizardPrimaryButton(text = "Make My Key", enabled = !isLoading, isLoading = isLoading, onClick = viewModel::generateNewUserKeys)
            return@Column
        }

        WizardCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Key, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Secret key", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                TextButton(onClick = { shown = !shown }, modifier = Modifier.heightIn(min = 44.dp)) {
                    Text(if (shown) "Hide" else "Show", color = WizardAccent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(
                text = if (shown) nsec else "•".repeat(24),
                color = if (shown) WizardAccent else WizardTextMuted,
                fontSize = 13.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(WizardBgElevated)
                    .border(1.dp, WizardBorderSubtle, RoundedCornerShape(8.dp))
                    .padding(10.dp)
                    .clearAndSetSemantics { contentDescription = if (shown) "Secret key shown" else "Secret key hidden" },
            )
        }
        Spacer(Modifier.height(14.dp))
        Text(
            "Anyone with it can post as you. Nobody can get it back for you, not even us.",
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(28.dp))
        WizardPrimaryButton(text = "Next", onClick = viewModel::advanceFromNostrIntro)
        Spacer(Modifier.height(8.dp))
    }
}

/** You = key. */
@Composable
private fun YouEqualsKey(name: String, photo: ByteArray?) {
    val preview = remember(photo) {
        photo?.let { android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() }
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(18.dp),
        modifier = Modifier.clearAndSetSemantics { contentDescription = "$name equals your key" },
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(92.dp)
                    .clip(CircleShape)
                    .background(WizardBgElevated)
                    .border(2.dp, WizardBorderActive, CircleShape),
            ) {
                if (preview != null) {
                    androidx.compose.foundation.Image(
                        bitmap = preview,
                        contentDescription = null,
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(Icons.Default.Person, contentDescription = null, tint = WizardTextMuted, modifier = Modifier.size(44.dp))
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(name, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.widthIn(max = 120.dp))
        }
        Text("=", color = WizardTextMuted, fontSize = 40.sp, fontWeight = FontWeight.Bold)
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(contentAlignment = Alignment.Center, modifier = Modifier.size(92.dp)) {
                Icon(
                    Icons.Default.Key,
                    contentDescription = null,
                    tint = WizardAccent,
                    modifier = Modifier.size(64.dp).shadow(14.dp, CircleShape, ambientColor = WizardAccentGlow, spotColor = WizardAccentGlow, clip = false),
                )
            }
            Spacer(Modifier.height(8.dp))
            Text("Your key", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

private fun displayName(name: String): String = name.trim().ifEmpty { "You" }
