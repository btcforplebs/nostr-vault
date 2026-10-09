package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.text.style.TextOverflow
import com.nostrvault.ui.components.AvatarImage
import androidx.compose.foundation.background
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import coil.compose.AsyncImage
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.NostrService
import com.nostrvault.ui.notification.NotificationManager
import kotlin.coroutines.cancellation.CancellationException
import androidx.compose.animation.Crossfade
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import com.nostrvault.di.ApplicationScope
import kotlinx.serialization.json.JsonPrimitive
import javax.inject.Inject

/**
 * Edit Profile, opened over your own profile as a sheet (pull the page down,
 * or the Edit Profile button). There is no Save button: swiping the sheet
 * away, Back or Done saves; Discard closes without saving (iOS #456).
 *
 * Scoped to the profile page, so an edit that failed to publish is still
 * here when the sheet next opens. The publish itself runs app-wide.
 */
@HiltViewModel
class ProfileEditViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val notificationManager: NotificationManager,
    /** Runs the publish, so leaving the profile page right after a save does not cancel it. */
    @ApplicationScope private val appScope: CoroutineScope,
) : ViewModel() {

    private val _displayName = MutableStateFlow("")
    val displayName = _displayName.asStateFlow()

    private val _name = MutableStateFlow("")
    val name = _name.asStateFlow()

    private val _about = MutableStateFlow("")
    val about = _about.asStateFlow()

    private val _pictureUrl = MutableStateFlow("")
    val pictureUrl = _pictureUrl.asStateFlow()

    private val _bannerUrl = MutableStateFlow("")
    val bannerUrl = _bannerUrl.asStateFlow()

    private val _nip05 = MutableStateFlow("")
    val nip05 = _nip05.asStateFlow()

    private val _lud16 = MutableStateFlow("")
    val lud16 = _lud16.asStateFlow()

    private val _website = MutableStateFlow("")
    val website = _website.asStateFlow()

    /** Whose profile this is, for the preview's placeholder avatar. */
    val pubkey: String get() = configStore.activeAccountHexPubkey.value

    /** What the form showed when opened, by kind-0 key: a save applies only fields changed from it. */
    private var initialFields: Map<String, String> = emptyMap()
    /** The profile the form was filled from. */
    private var existing: FeedProfile? = null
    /** Fields from a save that did not reach the relays; the next open lays them over the form. */
    private var unsavedDraft: Map<String, String>? = null
    /** Between [open] and [close], so a second dismiss callback does not save twice. */
    private var isOpen = false

    /** Fills the form from your profile as shown now, plus anything a failed save left. */
    fun open() {
        val pubkey = pubkey
        val profile = nostrService.profiles.value[pubkey] ?: FeedProfile(pubkey = pubkey)
        existing = profile
        _displayName.value = profile.displayName ?: ""
        _name.value = profile.name ?: ""
        _about.value = profile.about ?: ""
        _pictureUrl.value = profile.pictureURL ?: ""
        _bannerUrl.value = profile.bannerURL ?: ""
        _nip05.value = profile.nip05 ?: ""
        _lud16.value = profile.lud16 ?: ""
        _website.value = profile.website ?: ""
        initialFields = formFields()
        unsavedDraft?.let(::applyFields)
        isOpen = true
    }

    private fun applyFields(fields: Map<String, String>) {
        for ((key, value) in fields) {
            when (key) {
                ProfileMetadataMerge.DISPLAY_NAME -> _displayName.value = value
                ProfileMetadataMerge.NAME -> _name.value = value
                ProfileMetadataMerge.ABOUT -> _about.value = value
                ProfileMetadataMerge.PICTURE -> _pictureUrl.value = value
                ProfileMetadataMerge.BANNER -> _bannerUrl.value = value
                ProfileMetadataMerge.NIP05 -> _nip05.value = value
                ProfileMetadataMerge.LUD16 -> _lud16.value = value
                ProfileMetadataMerge.WEBSITE -> _website.value = value
            }
        }
    }

    private fun formFields(): Map<String, String> = mapOf(
        ProfileMetadataMerge.DISPLAY_NAME to _displayName.value,
        ProfileMetadataMerge.NAME to _name.value,
        ProfileMetadataMerge.ABOUT to _about.value,
        ProfileMetadataMerge.PICTURE to _pictureUrl.value,
        ProfileMetadataMerge.BANNER to _bannerUrl.value,
        ProfileMetadataMerge.NIP05 to _nip05.value,
        ProfileMetadataMerge.LUD16 to _lud16.value,
        ProfileMetadataMerge.WEBSITE to _website.value,
    )

    fun hasChanges(): Boolean = ProfileMetadataMerge.hasChanges(initialFields, formFields())

    fun setDisplayName(v: String) { _displayName.value = v }
    fun setName(v: String) { _name.value = v }
    fun setAbout(v: String) { _about.value = v }
    fun setPictureUrl(v: String) { _pictureUrl.value = v }
    fun setBannerUrl(v: String) { _bannerUrl.value = v }
    fun setNip05(v: String) { _nip05.value = v }
    fun setLud16(v: String) { _lud16.value = v }
    fun setWebsite(v: String) { _website.value = v }

    /**
     * The sheet went away. Unless [discard], changed fields show on the page
     * at once and publish behind; if that fails the page goes back to what it
     * showed and the next open restores the changes.
     */
    fun close(discard: Boolean) {
        if (!isOpen) return
        isOpen = false
        if (discard) {
            unsavedDraft = null
            return
        }
        val initial = initialFields
        val edited = formFields()
        val existing = existing ?: return
        if (!ProfileMetadataMerge.hasChanges(initial, edited)) return
        val pubkey = existing.pubkey
        val shownBefore = nostrService.profiles.value[pubkey]
        unsavedDraft = null
        nostrService.showLocalProfile(pubkey, ProfileMetadataMerge.preview(existing, initial, edited))
        appScope.launch(Dispatchers.Main) {
            val published = publish(existing, initial, edited)
            if (published != null) {
                nostrService.showLocalProfile(pubkey, published)
            } else {
                nostrService.showLocalProfile(pubkey, shownBefore)
                unsavedDraft = edited
                notificationManager.showError("Profile not saved. Pull down to try again.")
            }
        }
    }

    /** Publishes the changed fields as a new kind 0; the profile it describes, or null if nothing was published. */
    private suspend fun publish(existing: FeedProfile, initial: Map<String, String>, edited: Map<String, String>): FeedProfile? {
        // A kind 0 replaces the whole profile. Start from the newest one on
        // the relays so lud06 and every key this form doesn't show
        // survive; if it can't be fetched, publishing would wipe them, so
        // don't (same rule as the follow list, #180).
        val pubkey = existing.pubkey
        val alsoAsk = nostrService.outboxRelays.value[pubkey].orEmpty() +
            nostrService.relayLists.value[pubkey].orEmpty()
        val lookup = nostrService.lookupNewestReplaceable(0, pubkey, alsoAsk)
        if (lookup.event == null && !lookup.confirmedNone) return null
        val merged = ProfileMetadataMerge.merge(ProfileMetadataMerge.parseContent(lookup.event?.content), initial, edited)
        // A bunker timeout or an Amber rejection throws; uncaught here it
        // crashed the app.
        val event = try {
            nostrService.signEventAsync(kind = 0, content = merged.toString(), tags = emptyList())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            null
        } ?: return null
        nostrService.postEvent(event)
        return ProfileMetadataMerge.profile(existing, merged).copy(
            lud06 = (merged["lud06"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
            createdAt = event.createdAt,
        )
    }
}

/**
 * The Edit Profile sheet, for a [viewModel] that has been [ProfileEditViewModel.open]ed.
 * [onClose] runs once it has gone, however it went; the view model has
 * already saved or discarded by then.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileEditSheet(
    viewModel: ProfileEditViewModel,
    onClose: () -> Unit,
) {
    val displayName by viewModel.displayName.collectAsState()
    val name by viewModel.name.collectAsState()
    val about by viewModel.about.collectAsState()
    val pictureUrl by viewModel.pictureUrl.collectAsState()
    val bannerUrl by viewModel.bannerUrl.collectAsState()
    val nip05 by viewModel.nip05.collectAsState()
    val lud16 by viewModel.lud16.collectAsState()
    val website by viewModel.website.collectAsState()
    val hasChanges = remember(displayName, name, about, pictureUrl, bannerUrl, nip05, lud16, website) {
        viewModel.hasChanges()
    }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    // Done and Discard slide the sheet away first; a swipe or Back has
    // already moved it by the time onDismissRequest runs.
    fun dismiss(discard: Boolean) {
        viewModel.close(discard)
        scope.launch { sheetState.hide() }.invokeOnCompletion { onClose() }
    }

    ModalBottomSheet(
        onDismissRequest = { viewModel.close(discard = false); onClose() },
        sheetState = sheetState,
        containerColor = WindowBackground,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        EditSheetHeader(
            hasChanges = hasChanges,
            onDiscard = { dismiss(discard = true) },
            onDone = { dismiss(discard = false) },
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(16.dp))
            BannerPreview(bannerUrl)
            ProfilePreview(
                pubkey = viewModel.pubkey,
                pictureUrl = pictureUrl,
                displayName = displayName,
                name = name,
                nip05 = nip05,
                about = about,
            )
            HorizontalDivider(color = SeparatorColor.copy(alpha = 0.5f), modifier = Modifier.padding(bottom = 16.dp))
            ProfileField("Display Name", displayName, viewModel::setDisplayName)
            ProfileField("Username", name, viewModel::setName)
            ProfileField("About", about, viewModel::setAbout, singleLine = false, minLines = 3)
            ProfileField("Profile Picture URL", pictureUrl, viewModel::setPictureUrl)
            ProfileField("Banner URL", bannerUrl, viewModel::setBannerUrl)
            ProfileField("NIP-05 Identifier", nip05, viewModel::setNip05)
            ProfileField("Lightning Address", lud16, viewModel::setLud16)
            ProfileField("Website", website, viewModel::setWebsite)
            Spacer(Modifier.height(32.dp))
        }
    }
}

/**
 * Discard (red, only once something changed), the title with what a swipe
 * will do, and Done. iOS ProfileEditView.autosaveHeader.
 */
@Composable
private fun EditSheetHeader(hasChanges: Boolean, onDiscard: () -> Unit, onDone: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Column {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 4.dp)
                .padding(bottom = 4.dp),
        ) {
            TextButton(onClick = onDiscard, enabled = hasChanges) {
                Text("Discard", color = if (hasChanges) ErrorRed else SecondaryText)
            }
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.weight(1f),
            ) {
                Text("Edit Profile", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Crossfade(targetState = hasChanges, label = "edit-subtitle") { changed ->
                    Text(
                        if (changed) "Swipe down to save" else "Swipe down to close",
                        color = SecondaryText,
                        fontSize = 11.sp,
                    )
                }
            }
            TextButton(onClick = onDone) {
                Text("Done", color = colors.primary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        HorizontalDivider(color = SeparatorColor.copy(alpha = 0.5f), thickness = 0.5.dp)
    }
}

/**
 * The Banner URL at the 3:1 shape the profile draws it in; nothing until the
 * field holds a link.
 */
@Composable
private fun BannerPreview(bannerUrl: String) {
    val url = bannerUrl.trim()
    if (!url.startsWith("http://") && !url.startsWith("https://")) return
    AsyncImage(
        model = url,
        contentDescription = "Banner preview",
        contentScale = ContentScale.Crop,
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(3f)
            .clip(RoundedCornerShape(8.dp))
            .background(LocalNostrVaultColors.current.primary.copy(alpha = 0.12f)),
    )
    Spacer(Modifier.height(12.dp))
}

/** How the profile will look, updating as the fields are edited. */
@Composable
private fun ProfilePreview(
    pubkey: String,
    pictureUrl: String,
    displayName: String,
    name: String,
    nip05: String,
    about: String,
) {
    val colors = LocalNostrVaultColors.current
    val shownName = displayName.ifBlank { name.ifBlank { "Unnamed" } }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp)
            .padding(bottom = 8.dp),
    ) {
        AvatarImage(
            url = pictureUrl.trim().ifEmpty { null },
            pubkey = pubkey,
            size = 56.dp,
            displayName = shownName,
            modifier = Modifier.border(1.5.dp, colors.primary.copy(alpha = 0.35f), CircleShape),
        )
        Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.weight(1f)) {
            Text(shownName, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (nip05.isNotBlank()) {
                Text(nip05, color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (about.isNotBlank()) {
                Text(about, color = PrimaryText.copy(alpha = 0.75f), fontSize = 12.sp,
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun ProfileField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    singleLine: Boolean = true,
    minLines: Int = 1,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = singleLine,
        minLines = minLines,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = LocalNostrVaultColors.current.primary,
            unfocusedBorderColor = SeparatorColor,
            cursorColor = LocalNostrVaultColors.current.primary,
            focusedLabelColor = LocalNostrVaultColors.current.primary,
        ),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 12.dp),
    )
}
