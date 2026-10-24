package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.ContentScale
import coil.compose.AsyncImage
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.service.BroadcastTally
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
 * Edit Profile, opened over your own profile as a sheet by the Edit Profile
 * button. Only Save publishes; Discard, Back, a swipe or a tap outside close
 * without saving, and while something changed the sheet can't be swiped or
 * backed away at all. Swipe-to-save published over the wrong account's
 * profile on a phone with two accounts (2026-10-24).
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
    private val photoUploader: ProfilePhotoUploader,
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

    /** The field a photo from Photos is being uploaded for, or null. */
    private val _uploading = MutableStateFlow<ProfilePhotoTarget?>(null)
    val uploading = _uploading.asStateFlow()

    /** Why the last photo did not upload, shown under the photo buttons. */
    private val _uploadError = MutableStateFlow<String?>(null)
    val uploadError = _uploadError.asStateFlow()

    /** The active account, whose profile [open] fills the form from. */
    val pubkey: String get() = configStore.activeAccountHexPubkey.value

    /** The account the form was filled from at [open]; only it may sign the save. */
    private var formAccount: String = ""

    /** What the form showed when opened, by kind-0 key: a save applies only fields changed from it. */
    private var initialFields: Map<String, String> = emptyMap()
    /** The profile the form was filled from. */
    private var existing: FeedProfile? = null
    /**
     * Fields from a save that did not reach the relays, and whose they are;
     * the next open lays them over that account's form only.
     */
    private var unsavedDraft: Pair<String, Map<String, String>>? = null
    /** Between [open] and [save] or [close], so a second callback does not save twice. */
    private var isOpen = false
    /** Counts saves, so a late answer for an older one can't undo a newer one. */
    private var saveGeneration = 0

    /** Fills the form from your profile as shown now, plus anything a failed save left. */
    fun open() {
        val pubkey = pubkey
        val profile = nostrService.profiles.value[pubkey] ?: FeedProfile(pubkey = pubkey)
        existing = profile
        formAccount = pubkey
        _displayName.value = profile.displayName ?: ""
        _name.value = profile.name ?: ""
        _about.value = profile.about ?: ""
        _pictureUrl.value = profile.pictureURL ?: ""
        _bannerUrl.value = profile.bannerURL ?: ""
        _nip05.value = profile.nip05 ?: ""
        _lud16.value = profile.lud16 ?: ""
        _website.value = profile.website ?: ""
        initialFields = formFields()
        unsavedDraft?.let { (account, fields) -> if (account == pubkey) applyFields(fields) }
        _uploadError.value = null
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
     * Uploads a photo from Photos and puts its URL in the picture or banner
     * field, as if pasted. Nothing is published until the sheet saves.
     */
    fun uploadPhoto(uri: android.net.Uri, target: ProfilePhotoTarget) {
        if (_uploading.value != null) return
        _uploading.value = target
        _uploadError.value = null
        viewModelScope.launch {
            try {
                val url = photoUploader.upload(uri, target)
                when (target) {
                    ProfilePhotoTarget.PICTURE -> _pictureUrl.value = url
                    ProfilePhotoTarget.BANNER -> _bannerUrl.value = url
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _uploadError.value = (e as? ProfilePhotoUploadException)?.message ?: ProfilePhotoUploader.UPLOAD_FAILED
            } finally {
                _uploading.value = null
            }
        }
    }

    /** Discard, Back, a swipe or a tap outside: closes without saving. */
    fun close() {
        if (!isOpen) return
        isOpen = false
        unsavedDraft = null
    }

    /**
     * The Save button. Changed fields show on the page at once and publish
     * behind; if that fails the page goes back to what it showed and the
     * next open as the same account restores the changes.
     */
    fun save() {
        if (!isOpen) return
        isOpen = false
        val initial = initialFields
        val edited = formFields()
        val existing = existing ?: return
        if (!ProfileMetadataMerge.hasChanges(initial, edited)) return
        val pubkey = existing.pubkey
        val formAccount = formAccount
        unsavedDraft = null
        // Taken now: the publish runs after the sheet is gone, behind a
        // lookup of up to 6 s, and a switch in that window must not sign
        // this profile as the other account.
        val lock = nostrService.lockPostingAccount()
        // The form was filled from [existing]'s profile. If the account
        // changed while the sheet was open, signing it as the one active now
        // would publish that profile as theirs, so nothing is saved.
        if (!ProfileEditGuard.maySign(signer = lock.hex, editedProfile = pubkey, formAccount = formAccount)) {
            notificationManager.showError(PostingAccount.MESSAGE)
            return
        }
        val shownBefore = nostrService.profiles.value[pubkey]
        val generation = ++saveGeneration
        nostrService.showLocalProfile(pubkey, ProfileMetadataMerge.preview(existing, initial, edited))
        // The page goes back to what it showed, and the next open brings back
        // what was typed. Not after a newer save: that one owns the page.
        fun rollBack(message: String) {
            if (generation != saveGeneration) return
            nostrService.showLocalProfile(pubkey, shownBefore)
            // Kept for the next open only while it is still this
            // account's form; after a switch it would fill the other
            // account's profile with these fields.
            if (nostrService.lockPostingAccount() == lock) unsavedDraft = pubkey to edited
            notificationManager.showError(message)
        }
        appScope.launch(Dispatchers.Main) {
            val published = publish(existing, initial, edited, lock, onRefused = {
                appScope.launch(Dispatchers.Main) { rollBack(SAVE_REFUSED) }
            })
            if (published != null) {
                nostrService.showLocalProfile(pubkey, published)
            } else {
                rollBack(SAVE_FAILED)
            }
        }
    }

    companion object {
        /** iOS MyProfileView's words for a save that never went out. */
        const val SAVE_FAILED = "Profile not saved. Tap Edit Profile to try again."
        /** iOS's words for one that went out and no relay took. */
        const val SAVE_REFUSED = "Profile not saved: no relay accepted it. Edit Profile still has your changes."
    }

    /** Publishes the changed fields as a new kind 0; the profile it describes, or null if nothing was published. */
    private suspend fun publish(
        existing: FeedProfile,
        initial: Map<String, String>,
        edited: Map<String, String>,
        lock: PostingAccount.Lock,
        /** Runs later if every relay turns the profile down or never answers. */
        onRefused: () -> Unit,
    ): FeedProfile? {
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
        // A bunker timeout, an Amber rejection or a switch away from [lock]
        // throws; uncaught here it crashed the app.
        val event = try {
            // The tags go too: NIP-39 `i` identities and NIP-30 emoji set
            // in other clients would be dropped by an empty list.
            nostrService.signEventAsync(kind = 0, content = merged.toString(), tags = lookup.event?.tags.orEmpty(), lockedTo = lock)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            null
        } ?: return null
        // The signer's word is not taken for whose key it used: a kind 0
        // under any other key would replace that account's profile.
        if (!ProfileEditGuard.maySign(signer = event.pubkey, editedProfile = pubkey, formAccount = lock.hex)) return null
        nostrService.postEvent(event) { outcome ->
            if (outcome == BroadcastTally.Outcome.REFUSED) onRefused()
        }
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
    val uploading by viewModel.uploading.collectAsState()
    val uploadError by viewModel.uploadError.collectAsState()
    val hasChanges = remember(displayName, name, about, pictureUrl, bannerUrl, nip05, lud16, website) {
        viewModel.hasChanges()
    }
    // A swipe, Back or a tap outside never saves. While something changed
    // or a photo uploads they are held, so typed edits can't be lost by
    // accident either: Save or Discard decides.
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = {
            it != SheetValue.Hidden ||
                ProfileEditGuard.closesOnSwipe(viewModel.hasChanges(), viewModel.uploading.value != null)
        },
    )
    val scope = rememberCoroutineScope()
    val closesOnSwipe = ProfileEditGuard.closesOnSwipe(hasChanges, uploading != null)
    // Save and Discard slide the sheet away first; a swipe or Back has
    // already moved it by the time onDismissRequest runs.
    fun dismiss(save: Boolean) {
        if (viewModel.uploading.value != null) return
        if (save) viewModel.save() else viewModel.close()
        scope.launch { sheetState.hide() }.invokeOnCompletion { onClose() }
    }

    ModalBottomSheet(
        onDismissRequest = {
            if (ProfileEditGuard.closesOnSwipe(viewModel.hasChanges(), viewModel.uploading.value != null)) {
                viewModel.close()
                onClose()
            }
        },
        sheetState = sheetState,
        properties = ModalBottomSheetProperties(shouldDismissOnBackPress = closesOnSwipe),
        containerColor = WindowBackground,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        EditSheetHeader(
            hasChanges = hasChanges,
            uploading = uploading != null,
            onDiscard = { dismiss(save = false) },
            onSave = { dismiss(save = true) },
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState()),
        ) {
            BannerPreview(bannerUrl)
            ProfilePreview(
                pubkey = viewModel.pubkey,
                pictureUrl = pictureUrl,
                displayName = displayName,
                name = name,
                nip05 = nip05,
                about = about,
            )
            // iOS ProfileEditView: IDENTITY, BIO, MEDIA, LIGHTNING, a rule before each.
            val values = mapOf(
                ProfileMetadataMerge.DISPLAY_NAME to (displayName to viewModel::setDisplayName),
                ProfileMetadataMerge.NAME to (name to viewModel::setName),
                ProfileMetadataMerge.ABOUT to (about to viewModel::setAbout),
                ProfileMetadataMerge.PICTURE to (pictureUrl to viewModel::setPictureUrl),
                ProfileMetadataMerge.BANNER to (bannerUrl to viewModel::setBannerUrl),
                ProfileMetadataMerge.NIP05 to (nip05 to viewModel::setNip05),
                ProfileMetadataMerge.LUD16 to (lud16 to viewModel::setLud16),
                ProfileMetadataMerge.WEBSITE to (website to viewModel::setWebsite),
            )
            for (group in ProfileEditLayout.groups) {
                ProfileEditGroupDivider()
                ProfileEditGroupTitle(group.title)
                if (group.photoPickers) {
                    // Its own 12 below; the 12 above and 16 sides match a field row.
                    Box(Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp)) {
                        ProfilePhotoButtons(uploading, uploadError, viewModel::uploadPhoto)
                    }
                    ProfileEditFieldDivider()
                }
                group.fields.forEachIndexed { index, field ->
                    if (index > 0) ProfileEditFieldDivider()
                    val (value, onChange) = values.getValue(field.key)
                    ProfileEditFieldRow(field, value, onChange)
                }
            }
            Spacer(Modifier.height(32.dp))
        }
    }
}

/**
 * Discard (red, only once something changed), the title, and Save (Done
 * while nothing changed: it only closes). Nothing else saves.
 */
@Composable
private fun EditSheetHeader(hasChanges: Boolean, uploading: Boolean, onDiscard: () -> Unit, onSave: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Column {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 4.dp)
                .padding(bottom = 4.dp),
        ) {
            TextButton(onClick = onDiscard, enabled = hasChanges && !uploading) {
                Text("Discard", color = if (hasChanges && !uploading) ErrorRed else SecondaryText)
            }
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.weight(1f),
            ) {
                Text("Edit Profile", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Crossfade(targetState = uploading to hasChanges, label = "edit-subtitle") { (busy, changed) ->
                    Text(
                        when {
                            busy -> "Uploading photo…"
                            changed -> "Tap Save to keep your changes"
                            else -> "Swipe down to close"
                        },
                        color = SecondaryText,
                        fontSize = 11.sp,
                    )
                }
            }
            TextButton(onClick = onSave, enabled = !uploading) {
                Text(if (hasChanges) "Save" else "Done", color = if (uploading) SecondaryText else colors.primary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        HorizontalDivider(color = SeparatorColor.copy(alpha = 0.5f), thickness = 0.5.dp)
    }
}

/**
 * The Banner URL at the 3:1 shape the profile draws it in, edge to edge as
 * iOS; nothing until the field holds a link.
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
            .clipToBounds()
            .background(LocalNostrVaultColors.current.primary.copy(alpha = 0.12f)),
    )
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
            .padding(16.dp),
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
