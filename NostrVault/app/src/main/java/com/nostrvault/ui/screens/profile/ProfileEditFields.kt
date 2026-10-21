package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/** How a field's keyboard behaves. iOS ProfileEditView.KeyboardKind. */
internal enum class ProfileEditKeyboard { DEFAULT, URL, EMAIL }

/** One Edit Profile field: the kind-0 key it edits, its label and its placeholder. */
internal data class ProfileEditField(
    val key: String,
    val label: String,
    val placeholder: String,
    val keyboard: ProfileEditKeyboard = ProfileEditKeyboard.DEFAULT,
    val multiline: Boolean = false,
)

/** A titled block of fields; [photoPickers] puts the Choose picture / banner buttons first. */
internal data class ProfileEditGroup(
    val title: String,
    val fields: List<ProfileEditField>,
    val photoPickers: Boolean = false,
)

/**
 * The Edit Profile form, in iOS ProfileEditView's groups, order, labels and
 * placeholders. Only the layout: the same eight kind-0 keys are saved.
 */
internal object ProfileEditLayout {
    val groups: List<ProfileEditGroup> = listOf(
        ProfileEditGroup(
            "IDENTITY",
            listOf(
                ProfileEditField(ProfileMetadataMerge.DISPLAY_NAME, "Display Name", "Satoshi Nakamoto"),
                ProfileEditField(ProfileMetadataMerge.NAME, "Username", "satoshi"),
                ProfileEditField(ProfileMetadataMerge.NIP05, "NIP-05", "you@domain.com", ProfileEditKeyboard.EMAIL),
            ),
        ),
        ProfileEditGroup(
            "BIO",
            listOf(ProfileEditField(ProfileMetadataMerge.ABOUT, "About", "Tell people about yourself…", multiline = true)),
        ),
        ProfileEditGroup(
            "MEDIA",
            listOf(
                ProfileEditField(ProfileMetadataMerge.PICTURE, "Picture URL", "https://…", ProfileEditKeyboard.URL),
                ProfileEditField(ProfileMetadataMerge.BANNER, "Banner URL", "https://…", ProfileEditKeyboard.URL),
                ProfileEditField(ProfileMetadataMerge.WEBSITE, "Website", "yourdomain.com", ProfileEditKeyboard.URL),
            ),
            photoPickers = true,
        ),
        ProfileEditGroup(
            "LIGHTNING",
            listOf(ProfileEditField(ProfileMetadataMerge.LUD16, "Address (lud16)", "you@walletofsatoshi.com", ProfileEditKeyboard.EMAIL)),
        ),
    )
}

/** The rule between groups: full width, 8 above and below. */
@Composable
internal fun ProfileEditGroupDivider() {
    Box(
        Modifier
            .padding(vertical = 8.dp)
            .fillMaxWidth()
            .height(0.5.dp)
            .background(SeparatorColor.copy(alpha = 0.5f)),
    )
}

/** The rule between fields in a group, inset 16 on the leading side. */
@Composable
internal fun ProfileEditFieldDivider() {
    Box(
        Modifier
            .padding(start = 16.dp)
            .fillMaxWidth()
            .height(0.5.dp)
            .background(SeparatorColor.copy(alpha = 0.4f)),
    )
}

/** A group's small heavy capitals title. iOS ProfileEditView.fieldGroup. */
@Composable
internal fun ProfileEditGroupTitle(title: String) {
    Text(
        text = title,
        color = SecondaryText,
        fontSize = 10.sp,
        fontWeight = FontWeight.ExtraBold,
        letterSpacing = 0.7.sp,
        modifier = Modifier
            .padding(horizontal = 16.dp)
            .padding(bottom = 6.dp)
            .semantics { heading(); contentDescription = title.lowercase().replaceFirstChar { it.uppercase() } },
    )
}

/** One field, single-line beside its label or multi-line under it, as iOS draws them. */
@Composable
internal fun ProfileEditFieldRow(field: ProfileEditField, value: String, onValueChange: (String) -> Unit) {
    val accent = LocalNostrVaultColors.current.primary
    val style = TextStyle(color = PrimaryText, fontSize = 13.sp)
    val keyboard = when (field.keyboard) {
        ProfileEditKeyboard.URL -> KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Uri)
        ProfileEditKeyboard.EMAIL -> KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Email)
        ProfileEditKeyboard.DEFAULT -> KeyboardOptions(capitalization = KeyboardCapitalization.Sentences)
    }
    val placeholder = @Composable {
        if (value.isEmpty()) {
            Text(field.placeholder, color = TertiaryText, fontSize = 13.sp, maxLines = if (field.multiline) Int.MAX_VALUE else 1,
                modifier = Modifier.clearAndSetSemantics {})
        }
    }
    val label = @Composable { modifier: Modifier ->
        // Read once, as the field's own description, not as a separate line.
        Text(field.label, color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
            modifier = modifier.clearAndSetSemantics {})
    }
    // The whole row is the text field, so a tap anywhere on it starts typing.
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = !field.multiline,
        textStyle = style,
        cursorBrush = SolidColor(accent),
        keyboardOptions = keyboard,
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = field.label },
        decorationBox = { inner ->
            if (field.multiline) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                ) {
                    label(Modifier)
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(6.dp))
                            .background(SecondaryText.copy(alpha = 0.08f))
                            .heightIn(min = 102.dp)
                            .padding(12.dp),
                    ) {
                        placeholder()
                        inner()
                    }
                }
            } else {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                ) {
                    label(Modifier.width(100.dp))
                    Box(Modifier.weight(1f)) {
                        placeholder()
                        inner()
                    }
                }
            }
        },
    )
}
