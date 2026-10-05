package com.nostrvault.ui.screens

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.model.ListingDraft
import com.nostrvault.data.model.MarketCategory
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground

private const val MAX_PHOTOS = 8

/**
 * Lists something for sale as a NIP-99 classified (kind 30402). Port of the
 * iPhone's MarketplaceSellView. There is no checkout in the app: buyers find
 * the listing here, on Shopstr or on Plebeian, and pay the seller on the web.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MarketplaceSellScreen(onDone: () -> Unit, viewModel: ModeComposeViewModel) {
    val colors = LocalNostrVaultColors.current
    val busy by viewModel.busy.collectAsState()
    val status by viewModel.status.collectAsState()
    val error by viewModel.error.collectAsState()

    var title by rememberSaveable { mutableStateOf("") }
    var summary by rememberSaveable { mutableStateOf("") }
    var description by rememberSaveable { mutableStateOf("") }
    var price by rememberSaveable { mutableStateOf("") }
    var currency by rememberSaveable { mutableStateOf("SATS") }
    var category by rememberSaveable { mutableStateOf(MarketCategory.OTHER) }
    var location by rememberSaveable { mutableStateOf("") }
    var photos by rememberSaveable(
        stateSaver = listSaver<List<Uri>, String>({ it.map(Uri::toString) }, { it.map(Uri::parse) }),
    ) { mutableStateOf(emptyList()) }

    // Placeholder URLs stand in for photos that are not uploaded yet, so
    // isComplete can gate the List it button the same way it gates publishing.
    val draft = ListingDraft(
        title = title, summary = summary, description = description, price = price,
        currency = currency, category = category, location = location,
        imageUrls = photos.map { "https://pending.invalid" },
    )

    BackHandler(enabled = busy) {}

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Sell something") },
                navigationIcon = {
                    IconButton(onClick = onDone, enabled = !busy) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Cancel")
                    }
                },
                actions = {
                    Button(
                        onClick = { viewModel.publishListing(draft.copy(imageUrls = emptyList()), photos, onDone) },
                        enabled = draft.isComplete && !busy,
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                        shape = RoundedCornerShape(20.dp),
                        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
                    ) {
                        if (busy) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = PrimaryText)
                        } else {
                            Text("List it", fontWeight = FontWeight.SemiBold, color = PrimaryText)
                        }
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
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            PhotoStrip(photos = photos, enabled = !busy, onChange = { photos = it })
            Text("At least one photo. The first is the cover in the grid.", color = SecondaryText, fontSize = 12.sp)

            SellField(title, { title = it }, "What are you selling?")
            SellField(summary, { summary = it }, "One-line summary (optional)")

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = price,
                    onValueChange = { price = it },
                    label = { Text("Price") },
                    placeholder = { Text(if (currency == "SATS") "21000" else "45.00") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                Picker(
                    label = if (currency == "SATS") "sats" else currency,
                    options = ListingDraft.CURRENCIES,
                    optionLabel = { if (it == "SATS") "sats" else it },
                    onPick = { currency = it },
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Category", color = SecondaryText, fontSize = 14.sp, modifier = Modifier.weight(1f))
                Picker(
                    label = if (category == MarketCategory.OTHER) "None" else category.displayName,
                    options = MarketCategory.entries,
                    optionLabel = { if (it == MarketCategory.OTHER) "None" else it.displayName },
                    onPick = { category = it },
                )
            }
            SellField(location, { location = it }, "Location (optional)")
            SellField(description, { description = it }, "Description", minLines = 5)
            Text(
                "Condition, size, shipping, and how buyers should pay or reach you. " +
                    "Buyers see this here and on Plebeian Market, and can message you from the listing.",
                color = SecondaryText,
                fontSize = 12.sp,
            )

            status?.let {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.primary)
                    Text(it, color = SecondaryText, fontSize = 13.sp)
                }
            }
            error?.let { Text(it, color = Color(0xFFFF453A), fontSize = 13.sp) }
        }
    }
}

@Composable
private fun SellField(value: String, onChange: (String) -> Unit, label: String, minLines: Int = 1) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        minLines = minLines,
        singleLine = minLines == 1,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun <T> Picker(label: String, options: List<T>, optionLabel: (T) -> String, onPick: (T) -> Unit) {
    val colors = LocalNostrVaultColors.current
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }) { Text("$label ▾", color = colors.primary) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { option ->
                DropdownMenuItem(text = { Text(optionLabel(option)) }, onClick = { onPick(option); open = false })
            }
        }
    }
}

@Composable
private fun PhotoStrip(photos: List<Uri>, enabled: Boolean, onChange: (List<Uri>) -> Unit) {
    val colors = LocalNostrVaultColors.current
    val remaining = MAX_PHOTOS - photos.size
    // The multi-picker needs a limit of at least 2; with one slot left, pick one.
    val pickMany = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(MAX_PHOTOS),
    ) { uris -> onChange((photos + uris).distinct().take(MAX_PHOTOS)) }
    val pickOne = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) onChange((photos + uri).distinct().take(MAX_PHOTOS))
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.horizontalScroll(rememberScrollState()),
    ) {
        photos.forEachIndexed { index, uri ->
            Box {
                AsyncImage(
                    model = uri,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(88.dp)
                        .clip(RoundedCornerShape(10.dp)),
                )
                if (index == 0) {
                    Text(
                        "Cover",
                        color = Color.White,
                        fontSize = 9.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier
                            .align(Alignment.BottomStart)
                            .padding(5.dp)
                            .clip(CircleShape)
                            .background(colors.primary)
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
                if (enabled) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(4.dp)
                            .size(22.dp)
                            .clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.6f))
                            .clickable { onChange(photos - uri) },
                    ) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Remove photo", tint = Color.White, modifier = Modifier.size(14.dp))
                    }
                }
            }
        }
        if (remaining > 0 && enabled) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
                modifier = Modifier
                    .size(88.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(Color.White.copy(alpha = 0.08f))
                    .clickable {
                        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        if (remaining >= 2) pickMany.launch(request) else pickOne.launch(request)
                    },
            ) {
                Icon(NostrVaultIcons.Media, contentDescription = null, tint = colors.primary, modifier = Modifier.size(22.dp))
                Text("Add photos", color = colors.primary, fontSize = 11.sp, modifier = Modifier.width(80.dp), maxLines = 1)
            }
        }
    }
}
