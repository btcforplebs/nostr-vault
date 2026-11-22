package com.nostrvault.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.components.ProseKeyboardOptions
import com.nostrvault.ui.theme.*

/**
 * The first new-account step (setup screens r3, Logen 2026-11-22): a big
 * photo circle that is itself the photo picker, one large name field, one
 * line and Next, drawn like the other setup steps. Nothing is uploaded or
 * published here: the photo stays a local JPEG until setup completes and the
 * key can sign (publishNewAccount). Twin of iOS EditProfileStep (#2412).
 */
@Composable
internal fun EditProfileStep(viewModel: SetupWizardViewModel) {
    val name by viewModel.profileName.collectAsState()
    val nameError by viewModel.profileNameError.collectAsState()
    val photo by viewModel.profilePhotoJpeg.collectAsState()
    val photoError by viewModel.profilePhotoError.collectAsState()
    val focus = LocalFocusManager.current
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) viewModel.setProfilePhoto(uri)
    }
    val preview = remember(photo) {
        photo?.let { android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() }
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = "Edit Profile",
            color = PrimaryText,
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(top = 8.dp).semantics { heading() },
        )
        Spacer(Modifier.height(28.dp))

        // The whole circle is the photo button; the orange badge says so.
        Box(
            contentAlignment = Alignment.BottomEnd,
            // Not clipped here, so the badge can sit on the circle's edge.
            modifier = Modifier
                .clickable(
                    interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                    indication = null,
                    onClickLabel = if (photo == null) "Add profile photo" else "Change profile photo",
                ) {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                },
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(168.dp)
                    .clip(CircleShape)
                    .background(WizardBgElevated)
                    .border(2.dp, WizardBorderActive, CircleShape),
            ) {
                if (preview != null) {
                    androidx.compose.foundation.Image(
                        bitmap = preview,
                        contentDescription = "Profile photo",
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(Icons.Default.PhotoCamera, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(40.dp))
                        Spacer(Modifier.height(6.dp))
                        Text("Add photo", color = SecondaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .offset(x = (-2).dp, y = (-2).dp)
                    .size(48.dp)
                    .clip(CircleShape)
                    .background(WizardGradient)
                    .border(4.dp, WizardBgPrimary, CircleShape),
            ) {
                Icon(
                    imageVector = if (photo == null) Icons.Default.Add else Icons.Default.Edit,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(22.dp),
                )
            }
        }
        Spacer(Modifier.height(28.dp))

        TextField(
            value = name,
            onValueChange = viewModel::setProfileName,
            placeholder = {
                Text("Your name", color = WizardTextMuted, fontSize = 22.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            },
            singleLine = true,
            textStyle = TextStyle(color = PrimaryText, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center),
            colors = TextFieldDefaults.colors(
                focusedContainerColor = WizardBgCard,
                unfocusedContainerColor = WizardBgCard,
                errorContainerColor = WizardBgCard,
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
                errorIndicatorColor = Color.Transparent,
                cursorColor = WizardAccent,
            ),
            keyboardOptions = ProseKeyboardOptions.copy(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }),
            isError = nameError != null,
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 64.dp)
                .border(1.dp, if (nameError != null) Color(0xFFEF4444) else WizardBorderSubtle, RoundedCornerShape(16.dp))
                .semantics { contentDescription = "Your name" },
        )
        Spacer(Modifier.height(12.dp))
        val problem = nameError ?: photoError
        Text(
            text = problem ?: "This is how people see you. Change it any time.",
            color = if (problem == null) SecondaryText else Color(0xFFEF4444),
            fontSize = 15.sp,
            lineHeight = 20.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(32.dp))
        WizardPrimaryButton(
            text = "Next",
            onClick = {
                focus.clearFocus()
                viewModel.advanceFromProfile()
            },
        )
        Spacer(Modifier.height(8.dp))
    }
}
