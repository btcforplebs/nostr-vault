package com.nostrvault.ui.screens.browser

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.nostrvault.fips.FipsUrl
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * The in-app browser (iOS/Mac: InAppBrowserView.swift): Done, a Mesh/Web badge, the address bar and reload on
 * top; the page; back, forward, share and "Open in browser" below. A mesh page asks before a link leaves it.
 */
@Composable
fun InAppBrowserScreen(
    model: InAppBrowserModel,
    onClose: () -> Unit,
    onShare: (String) -> Unit,
    onOpenInBrowser: (String) -> Unit,
) {
    var badgeInfo by remember { mutableStateOf(false) }
    BackHandler { if (model.canGoBack) model.goBack() else onClose() }

    Column(Modifier.fillMaxSize().background(Color.Black).statusBarsPadding().navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onClose) { Text("Done", color = PrimaryText) }
            Badge(model.kind) { badgeInfo = true }
            Spacer(Modifier.width(6.dp))
            AddressBar(model, Modifier.weight(1f))
            IconButton(onClick = model::reloadOrStop) {
                Icon(if (model.isLoading) NostrVaultIcons.Dismiss else NostrVaultIcons.Refresh,
                    contentDescription = if (model.isLoading) "Stop" else "Reload", tint = PrimaryText)
            }
        }
        if (model.isLoading) LinearProgressIndicator(progress = { model.progress }, modifier = Modifier.fillMaxWidth().height(2.dp))
        model.meshStatus?.let {
            Text(it, color = SecondaryText, fontSize = 13.sp, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            AndroidView(factory = { model.webView }, modifier = Modifier.fillMaxSize())
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            IconButton(onClick = model::goBack, enabled = model.canGoBack) {
                Icon(NostrVaultIcons.Back, "Back", tint = if (model.canGoBack) PrimaryText else SecondaryText)
            }
            IconButton(onClick = model::goForward, enabled = model.canGoForward) {
                Icon(NostrVaultIcons.Navigate, "Forward", tint = if (model.canGoForward) PrimaryText else SecondaryText)
            }
            IconButton(onClick = { model.shareUrl?.let(onShare) }, enabled = model.shareUrl != null) {
                Icon(NostrVaultIcons.Share, "Share", tint = PrimaryText)
            }
            val system = model.systemBrowserUrl
            IconButton(onClick = { system?.let(onOpenInBrowser) }, enabled = system != null) {
                Icon(NostrVaultIcons.OpenExternal, "Open in Default Browser", tint = if (system != null) PrimaryText else SecondaryText)
            }
        }
    }

    model.leavingMesh?.let { url ->
        AlertDialog(
            onDismissRequest = { model.leavingMesh = null },
            title = { Text("Leave the mesh?") },
            text = { Text("${FipsUrl.hostOf(url) ?: url} is on the internet. It will see your IP address, as in any browser.") },
            confirmButton = { TextButton(onClick = model::leaveMesh) { Text("Open on the web") } },
            dismissButton = { TextButton(onClick = { model.leavingMesh = null }) { Text("Stay on the mesh") } },
        )
    }
    if (badgeInfo) {
        val mesh = model.kind == InAppBrowserModel.Kind.Mesh
        AlertDialog(
            onDismissRequest = { badgeInfo = false },
            title = { Text(if (mesh) "Mesh page" else "Web page") },
            text = {
                Text(
                    if (mesh) "Read over the FIPS mesh with this device's mesh key, not your Nostr key. The site never sees your IP address; the public seeds that route the mesh do."
                    else "Loaded from the internet. The site sees your IP address, as in any browser. Nothing you do here is kept after you close it.",
                )
            },
            confirmButton = { TextButton(onClick = { badgeInfo = false }) { Text("OK") } },
        )
    }
}

@Composable
private fun Badge(kind: InAppBrowserModel.Kind, onClick: () -> Unit) {
    val mesh = kind == InAppBrowserModel.Kind.Mesh
    Row(
        Modifier
            .background(if (mesh) Color(0xFF1E3A2A) else Color(0xFF2A2A2E), RoundedCornerShape(999.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .semantics { contentDescription = if (mesh) "Mesh page. Explains who can see this visit" else "Web page. Explains who can see this visit" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (mesh) NostrVaultIcons.Lock else NostrVaultIcons.Globe, null, tint = if (mesh) Color(0xFF7BD88F) else SecondaryText, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(4.dp))
        Text(if (mesh) "Mesh" else "Web", color = PrimaryText, fontSize = 13.sp)
    }
}

@Composable
private fun AddressBar(model: InAppBrowserModel, modifier: Modifier) {
    var editing by remember { mutableStateOf<String?>(null) }
    val focus = LocalFocusManager.current
    TextField(
        value = editing ?: model.address,
        onValueChange = { editing = it },
        singleLine = true,
        placeholder = { Text("Search or address", color = SecondaryText) },
        textStyle = androidx.compose.ui.text.TextStyle(fontSize = 14.sp, color = PrimaryText),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false),
        keyboardActions = KeyboardActions(onGo = {
            if (model.submit(editing ?: model.address)) { editing = null; focus.clearFocus() }
        }),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = Color(0xFF1C1C1E), unfocusedContainerColor = Color(0xFF1C1C1E),
            focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
        ),
        shape = RoundedCornerShape(10.dp),
        modifier = modifier.height(48.dp).onFocusChanged { if (!it.isFocused) editing = null }
            .semantics { contentDescription = "Address" },
    )
}

