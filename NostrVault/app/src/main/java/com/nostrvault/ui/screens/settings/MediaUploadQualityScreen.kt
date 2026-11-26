package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.service.media.UploadQuality
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground

/**
 * Settings > Media & Cache > Upload Quality: Standard or Original for photos and videos you post,
 * share, send in live chat or DM (Logen 2026-11-26). See [UploadQuality].
 * Apple twin: `Views/Settings/MediaUploadQualitySettingsView.swift` (plan A4).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaUploadQualityScreen(
    onBack: () -> Unit,
    viewModel: AdvancedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val picked = UploadQuality.normalized(config.uploadQuality)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Upload Quality") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
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
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            QualityChoice(
                key = UploadQuality.STANDARD,
                title = "Standard",
                detail = "Photos up to 2048 px, videos at 720p. Smaller files that upload and load faster.",
                on = picked == UploadQuality.STANDARD,
                onPick = viewModel::setUploadQuality,
            )
            QualityChoice(
                key = UploadQuality.ORIGINAL,
                title = "Original",
                detail = "Photos and videos go up as they are. Bigger files, and some media servers refuse large ones.",
                on = picked == UploadQuality.ORIGINAL,
                onPick = viewModel::setUploadQuality,
            )
            Caption(
                "For notes, shares, live chat and messages. Location is removed either way. " +
                    "The Media tab always keeps the original."
            )
        }
    }
}

@Composable
private fun QualityChoice(key: String, title: String, detail: String, on: Boolean, onPick: (String) -> Unit) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.RadioButton) { onPick(key) }
            .semantics { selected = on }
            .padding(vertical = 10.dp)
            .testTag("media.uploadQuality.$key"),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = PrimaryText, fontSize = 15.sp)
            Text(detail, color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 2.dp))
        }
        if (on) Icon(NostrVaultIcons.Check, contentDescription = null, tint = colors.primary, modifier = Modifier.padding(start = 12.dp).size(20.dp))
    }
}

/** The row in Media & Cache that opens [MediaUploadQualityScreen], with the current choice beside it. */
@Composable
internal fun UploadQualityRow(setting: String, onOpen: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen)
            .padding(vertical = 10.dp)
            .testTag("media.uploadQuality"),
    ) {
        Text("Upload Quality", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Text(UploadQuality.label(setting), color = SecondaryText, fontSize = 15.sp)
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText, modifier = Modifier.padding(start = 4.dp).size(18.dp))
    }
}
