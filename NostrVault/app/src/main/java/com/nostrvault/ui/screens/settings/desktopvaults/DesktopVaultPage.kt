package com.nostrvault.ui.screens.settings.desktopvaults

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WarningYellow
import com.nostrvault.ui.theme.WindowBackground

/** A Desktop Vaults page: the bar with Back and [title], and a scrolling column (as the other settings pages). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DesktopVaultPage(title: String, onBack: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(NostrVaultIcons.Back, contentDescription = "Back") }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
        ) {
            content()
            Spacer(Modifier.height(32.dp))
        }
    }
}

/** A section's footer line: orange when it says what went wrong, grey otherwise. */
@Composable
internal fun DesktopVaultNote(text: String, warn: Boolean = false) {
    Text(text, color = if (warn) WarningYellow else SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp, bottom = 4.dp))
}

/** Space between sections. */
@Composable
internal fun DesktopVaultGap() = Spacer(Modifier.height(20.dp))

internal val DesktopVaultTeal = Color(0xFF30B0C7)
