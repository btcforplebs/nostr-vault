package com.nostrvault.ui.screens.recovery

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface0

/**
 * Shown instead of the app when the encrypted store that holds the saved
 * passwords, account keys and the FIPS mesh key can't be opened (a keystore
 * that lost its key, as after some OS updates or a restore). Nothing is
 * deleted unless the person picks Start fresh and confirms it; before, a
 * second failed launch emptied the store by itself (Logen, 3.0.0 43).
 *
 * [onContinue] carries on with the store closed for this launch: signing
 * and the mesh stay off, and the next launch asks again.
 */
@Composable
fun CredentialRecoveryScreen(onContinue: () -> Unit) {
    val context = LocalContext.current
    var retryFailed by remember { mutableStateOf(false) }
    var confirmFresh by remember { mutableStateOf(false) }
    var freshFailed by remember { mutableStateOf(false) }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxSize()
            .background(Surface0)
            .systemBarsPadding()
            .padding(horizontal = 28.dp),
    ) {
        Text("Your saved keys can't be opened", color = PrimaryText, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(12.dp))
        Text(
            "Android didn't unlock the place this app keeps your passwords, account keys and mesh key. " +
                "They are still on this phone; nothing has been deleted. This can pass after a restart.",
            color = SecondaryText,
            fontSize = 15.sp,
            textAlign = TextAlign.Center,
        )
        if (retryFailed) {
            Spacer(Modifier.height(10.dp))
            Text("Still locked. Try restarting the phone, then open the app again.", color = ErrorRed, fontSize = 13.sp, textAlign = TextAlign.Center)
        }
        if (freshFailed) {
            Spacer(Modifier.height(10.dp))
            Text("Couldn't start fresh either. Nothing was changed.", color = ErrorRed, fontSize = 13.sp, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.height(28.dp))
        Button(
            onClick = { if (CredentialStore.retryOpen(context)) relaunch(context) else retryFailed = true },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Try again") }
        Spacer(Modifier.height(10.dp))
        OutlinedButton(onClick = onContinue, modifier = Modifier.fillMaxWidth()) { Text("Continue without them for now") }
        Spacer(Modifier.height(10.dp))
        TextButton(onClick = { confirmFresh = true }, modifier = Modifier.fillMaxWidth()) { Text("Start fresh…", color = ErrorRed) }
    }

    if (confirmFresh) {
        AlertDialog(
            onDismissRequest = { confirmFresh = false },
            title = { Text("Start fresh?") },
            text = {
                Text(
                    "The app forgets its saved passwords, account keys and mesh key, and you sign in again " +
                        "with your key or password. The locked copy stays on the phone. Your mesh address will change.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmFresh = false
                    if (CredentialStore.startFresh(context)) relaunch(context) else freshFailed = true
                }) { Text("Start fresh", color = ErrorRed) }
            },
            dismissButton = { TextButton(onClick = { confirmFresh = false }) { Text("Cancel") } },
        )
    }
}

/** A fresh process, so every service reads the store that is open now. */
private fun relaunch(context: android.content.Context) {
    val intent = context.packageManager
        .getLaunchIntentForPackage(context.packageName)
        ?.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK)
    context.startActivity(intent)
    Runtime.getRuntime().exit(0)
}
