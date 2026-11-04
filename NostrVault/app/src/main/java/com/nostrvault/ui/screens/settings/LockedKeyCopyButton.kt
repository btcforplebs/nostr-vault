package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NIP49Service
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * Reveal Private Key's second copy: the key locked with a password (NIP-49 ncryptsec), the safe one to take to another
 * app (NDK check step 4, Logen 2026-11-04). [password]: the one just typed to reveal the key, which locks it; with
 * none (an account kept without one), the user picks one first. Twin of iOS `LockedKeyCopyButton.swift`.
 */
@Composable
fun LockedKeyCopyButton(nsec: String, password: String?) {
    val context = LocalContext.current
    var copied by remember(nsec) { mutableStateOf(false) }
    var choosing by remember(nsec) { mutableStateOf(false) }
    var error by remember(nsec) { mutableStateOf<String?>(null) }
    var locking by remember(nsec) { mutableStateOf<String?>(null) } // the password to lock with, while it runs
    LaunchedEffect(locking) {
        val pw = locking ?: return@LaunchedEffect
        val locked = withContext(Dispatchers.Default) { LockedKeyExport.lock(nsec, pw) }
        locking = null
        if (locked == null) { error = LockedKeyExport.FAILED; return@LaunchedEffect }
        copySecretKey(context, locked)
        copied = true
        delay(2_000)
        copied = false
    }
    Column {
        TextButton(
            onClick = { error = null; if (password != null) locking = password else choosing = true },
            enabled = locking == null,
            modifier = Modifier.testTag("revealKey.copyLocked"),
        ) { Text(if (copied) "Copied!" else if (locking != null) "Locking…" else "Copy locked key (ncryptsec)") }
        Text(LockedKeyExport.CAPTION, color = SecondaryText, fontSize = 11.sp)
        error?.let { Text(it, color = ErrorRed, fontSize = 12.sp) }
    }
    if (choosing) {
        ChooseLockPasswordDialog(onLock = { choosing = false; locking = it }, onDismiss = { choosing = false })
    }
}

@Composable
private fun ChooseLockPasswordDialog(onLock: (String) -> Unit, onDismiss: () -> Unit) {
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    val problem = LockedKeyExport.passwordProblem(password, confirm)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Lock your key") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Choose the password that will open this copy.", color = SecondaryText, fontSize = 13.sp)
                OutlinedTextField(password, { password = it }, placeholder = { Text("Password (8 or more)") },
                    visualTransformation = PasswordVisualTransformation(), singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
                OutlinedTextField(confirm, { confirm = it }, placeholder = { Text("The same again") },
                    visualTransformation = PasswordVisualTransformation(), singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
                if (problem.isNotEmpty() && confirm.isNotEmpty()) Text(problem, color = ErrorRed, fontSize = 12.sp)
            }
        },
        confirmButton = { TextButton(onClick = { onLock(password) }, enabled = problem.isEmpty()) { Text("Lock and copy") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** The rules behind [LockedKeyCopyButton], kept apart for tests. */
object LockedKeyExport {
    const val CAPTION = "Your key locked with a password. Apps that take an ncryptsec (NIP-49) open it with the same password. Safer to move than the nsec."
    const val FAILED = "Couldn't lock the key. Nothing was copied."

    /** "" when [password] may lock a key (8 or more characters, typed the same twice), else why not. */
    fun passwordProblem(password: String, confirm: String): String = when {
        password.length < 8 -> "Password must be at least 8 characters"
        password != confirm -> "Passwords do not match"
        else -> ""
    }

    /** [nsec] locked with [password], or null when it can't be. [toHex] and [encrypt]: the bridge, replaced in tests. */
    fun lock(
        nsec: String,
        password: String,
        toHex: (String) -> String? = HavenBridge::decodeNsec,
        encrypt: (String, String) -> String = NIP49Service::encrypt,
    ): String? {
        if (password.isEmpty()) return null
        val hex = toHex(nsec) ?: return null
        return runCatching { encrypt(hex, password) }.getOrNull()?.takeIf { it.startsWith("ncryptsec1") }
    }
}
