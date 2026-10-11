package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.setup.IdentityInput
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

/**
 * Import Private Key, as iOS ImportKeySheetView: paste the key, and for the
 * Vault's own account choose the password it is encrypted with.
 */
@Composable
internal fun ImportKeyDialog(
    npub: String,
    isOwner: Boolean,
    viewModel: AccountSettingsViewModel,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val scope = rememberCoroutineScope()
    var key by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    val input = IdentityInput.parse(key)
    val encrypted = input is IdentityInput.EncryptedSecretKey
    // An nsec for the Vault's own account gets a new password; an ncryptsec
    // needs the one it was made with. Other accounts' nsecs need none.
    val asksNewPassword = isOwner && !encrypted
    val asksPassword = asksNewPassword || encrypted
    val fieldColors = OutlinedTextFieldDefaults.colors(
        focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
        cursorColor = colors.primary, focusedBorderColor = colors.primary,
    )

    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = { Text("Import Key") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = key,
                    onValueChange = { key = it.trim(); error = null },
                    label = { Text("Private Key") },
                    placeholder = { Text("nsec1… or ncryptsec1…") },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    colors = fieldColors,
                )
                if (asksPassword) {
                    Text(
                        if (encrypted) "Password for this key" else "Encrypt with Password",
                        color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it; error = null },
                        placeholder = { Text("Password") },
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        colors = fieldColors,
                    )
                }
                if (asksNewPassword) {
                    OutlinedTextField(
                        value = confirm,
                        onValueChange = { confirm = it; error = null },
                        placeholder = { Text("Confirm Password") },
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        colors = fieldColors,
                    )
                }
                error?.let { Text(it, color = ErrorRed, fontSize = 12.sp) }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    working = true
                    scope.launch {
                        val problem = viewModel.importKeyFor(npub, key, password, confirm)
                        working = false
                        if (problem == null) onDismiss() else error = problem
                    }
                },
                enabled = !working && key.isNotBlank() && (!asksPassword || password.isNotEmpty()) &&
                    (!asksNewPassword || confirm.isNotEmpty()),
            ) { Text("Import", color = colors.primary) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !working) { Text("Cancel") }
        },
    )
}
