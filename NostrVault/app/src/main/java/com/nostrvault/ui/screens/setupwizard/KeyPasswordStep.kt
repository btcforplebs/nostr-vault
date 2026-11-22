package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * Lock it in: the last key step (setup screens r3, Way 1c). The password
 * that encrypts the new nsec (NIP-49), under the VaultMark with the key in
 * its keyhole. Its own page so the fields sit above the keyboard without
 * scrolling. While a field has focus the picture and subtitle step aside.
 * Twin of iOS KeyPasswordStep (#2416).
 */
@Composable
internal fun KeyPasswordStep(viewModel: SetupWizardViewModel, onComplete: () -> Unit) {
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val passphrase by viewModel.passphrase.collectAsState()
    val confirmPassphrase by viewModel.confirmPassphrase.collectAsState()
    var showPassword by remember { mutableStateOf(false) }
    var passwordFocused by remember { mutableStateOf(false) }
    var confirmFocused by remember { mutableStateOf(false) }
    val isTyping = passwordFocused || confirmFocused
    val confirmFocus = remember { FocusRequester() }
    val isPasswordValid = passphrase.length >= 8 && passphrase == confirmPassphrase

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        AnimatedVisibility(visible = !isTyping) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Spacer(Modifier.height(8.dp))
                KeyStepsStrip(KeyStepPart.LOCK)
                Spacer(Modifier.height(14.dp))
                VaultMarkWithKey()
                Spacer(Modifier.height(10.dp))
            }
        }
        Text("Lock it in", color = PrimaryText, fontSize = 28.sp, fontWeight = FontWeight.Bold)
        AnimatedVisibility(visible = !isTyping) {
            Text(
                text = "A password locks your key in the vault on this device. It never leaves it, and we can't reset it.",
                color = SecondaryText,
                fontSize = 15.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        Spacer(Modifier.height(20.dp))

        OutlinedTextField(
            value = passphrase,
            onValueChange = viewModel::setPassphrase,
            label = { Text("Password (minimum 8 characters)") },
            singleLine = true,
            visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
            trailingIcon = {
                IconButton(onClick = { showPassword = !showPassword }) {
                    Icon(
                        imageVector = if (showPassword) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                        contentDescription = if (showPassword) "Hide password" else "Show password",
                        tint = WizardAccent,
                    )
                }
            },
            isError = passphrase.isNotEmpty() && passphrase.length < 8,
            supportingText = if (passphrase.isNotEmpty() && passphrase.length < 8) {
                { Text("Password must be at least 8 characters", color = ErrorRed) }
            } else null,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Next),
            keyboardActions = KeyboardActions(onNext = { confirmFocus.requestFocus() }),
            colors = wizardTextFieldColors(),
            modifier = Modifier
                .fillMaxWidth()
                .onFocusChanged { passwordFocused = it.isFocused },
        )
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            value = confirmPassphrase,
            onValueChange = viewModel::setConfirmPassphrase,
            label = { Text("Confirm password") },
            singleLine = true,
            visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
            isError = confirmPassphrase.isNotEmpty() && passphrase != confirmPassphrase,
            supportingText = if (confirmPassphrase.isNotEmpty() && passphrase != confirmPassphrase) {
                { Text("Passwords do not match", color = ErrorRed) }
            } else null,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = {
                if (isPasswordValid && !isLoading) viewModel.advanceFromKeyPassword(onComplete)
            }),
            colors = wizardTextFieldColors(),
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(confirmFocus)
                .onFocusChanged { confirmFocused = it.isFocused },
        )

        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = ErrorRed, fontSize = 13.sp)
        }

        // Above the warning so it stays above the keyboard while typing; the
        // warning was already read before a field took focus.
        Spacer(Modifier.height(16.dp))
        WizardPrimaryButton(
            text = "Lock",
            enabled = isPasswordValid,
            isLoading = isLoading,
            onClick = { viewModel.advanceFromKeyPassword(onComplete) },
        )
        Spacer(Modifier.height(16.dp))
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(WizardAccent.copy(alpha = 0.08f))
                .border(1.dp, WizardBorderActive, RoundedCornerShape(12.dp))
                .padding(14.dp)
                .semantics(mergeDescendants = true) {},
        ) {
            Icon(Icons.Default.Shield, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
            Text(
                "Write this password down and keep it with your spare.",
                color = SecondaryText,
                fontSize = 13.sp,
                lineHeight = 18.sp,
            )
        }
    }
}

/** The VaultMark arch with the key sitting in its glowing keyhole. */
@Composable
private fun VaultMarkWithKey() {
    Box(contentAlignment = Alignment.BottomCenter, modifier = Modifier.padding(vertical = 4.dp)) {
        androidx.compose.foundation.Image(
            painter = androidx.compose.ui.res.painterResource(com.nostrvault.R.drawable.vault_mark),
            contentDescription = null,
            modifier = Modifier.size(92.dp).clip(RoundedCornerShape(20.dp)),
        )
        Icon(
            Icons.Default.Key,
            contentDescription = null,
            tint = WizardAccent,
            modifier = Modifier.offset(y = 6.dp).size(26.dp),
        )
    }
}
