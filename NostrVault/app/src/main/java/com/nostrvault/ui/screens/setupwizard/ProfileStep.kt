package com.nostrvault.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.Image
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch
import com.nostrvault.ui.components.ProseKeyboardOptions

@Composable
internal fun ProfileStep(viewModel: SetupWizardViewModel) {
    val name by viewModel.profileName.collectAsState()
    val photo by viewModel.profilePhotoJpeg.collectAsState()
    val photoError by viewModel.profilePhotoError.collectAsState()
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
            text = "Your Profile",
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "This is how people will see you. You can change it later.",
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 22.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(24.dp))

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .clip(RoundedCornerShape(12.dp))
                .clickable(onClickLabel = if (photo == null) "Add profile photo" else "Change profile photo") {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }
                .padding(8.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(104.dp)
                    .clip(CircleShape)
                    .background(WizardBgElevated)
                    .border(1.dp, WizardAccent, CircleShape),
            ) {
                if (preview != null) {
                    androidx.compose.foundation.Image(
                        bitmap = preview,
                        contentDescription = "Profile photo",
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        imageVector = Icons.Default.PhotoCamera,
                        contentDescription = null,
                        tint = SecondaryText,
                        modifier = Modifier.size(32.dp),
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = if (photo == null) "Add Photo" else "Change Photo",
                color = WizardAccent,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
            )
        }
        photoError?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = SecondaryText, fontSize = 13.sp)
        }

        Spacer(Modifier.height(20.dp))
        OutlinedTextField(
            value = name,
            onValueChange = viewModel::setProfileName,
            label = { Text("Name") },
            placeholder = { Text("Your name") },
            singleLine = true,
            colors = wizardTextFieldColors(),
            keyboardOptions = ProseKeyboardOptions.copy(imeAction = ImeAction.Done),
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(24.dp))
        WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromProfile)
        Spacer(Modifier.height(8.dp))
        TextButton(onClick = viewModel::skipProfile) {
            Text("Skip for Now", color = SecondaryText, fontSize = 14.sp)
        }
    }
}
