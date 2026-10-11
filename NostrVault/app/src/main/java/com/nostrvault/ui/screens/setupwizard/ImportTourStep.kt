package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.setup.ImportTourStage
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import java.text.NumberFormat

// ══════════════════════════════════════════════════════════════════
// Import tour
// ══════════════════════════════════════════════════════════════════

/** The small orange label over each lesson (mockup). */
private val TourKickers = listOf("WHY IMPORT", "HOW IT WORKS", "RELAYS", "OPTIONAL", "FEEDS")

/**
 * The import starts as soon as this shows. Over it, the import tour's lesson
 * cards at the reader's own pace, then a Ready card with real counts. Import
 * done first: "Jump in" shows under any card. Cards done first: the app can
 * open with the import still running (it lives in RelayImportService, not here).
 */
@Composable
internal fun ImportTourStep(viewModel: SetupWizardViewModel, onComplete: () -> Unit) {
    val isImporting by viewModel.tourIsImporting.collectAsState()
    val completed by viewModel.tourImportCompleted.collectAsState()
    val progress by viewModel.tourImportProgress.collectAsState()
    val status by viewModel.tourImportStatus.collectAsState()
    val counts by viewModel.tourCounts.collectAsState()
    val setupMode = viewModel.setupModeNow()
    val lessons = TutorialContent.importTour
    val lastIndex = lessons.size // the Ready card
    var index by rememberSaveable { mutableIntStateOf(0) }
    val done = completed && !isImporting
    // It ran and stopped without finishing: let them in anyway.
    val failed by viewModel.tourImportFailed.collectAsState()
    val stage = if (failed) ImportTourStage("The import stopped", 1) else ImportTourStage.from(status, done)
    // Kept running or not, the import carries on in RelayImportService.
    val enter = { viewModel.enterFromImportTour(sawEveryCard = index >= lastIndex, onComplete = onComplete) }

    LaunchedEffect(Unit) { viewModel.startImportTour() }
    LaunchedEffect(done) { if (done) viewModel.loadTourCounts() }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Bringing your notes home", color = PrimaryText, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(16.dp))

        // Progress
        Column(
            Modifier
                .fillMaxWidth()
                .clearAndSetSemantics {
                    contentDescription = "Import"
                    stateDescription = stage.text
                },
        ) {
            Row(Modifier.fillMaxWidth()) {
                Text(
                    stage.text,
                    color = when {
                        done -> SuccessGreen
                        failed -> ErrorRed
                        else -> SecondaryText
                    },
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.weight(1f),
                )
                Text("${stage.step} of ${ImportTourStage.STEP_COUNT}", color = Muted, fontSize = 12.sp)
            }
            Spacer(Modifier.height(6.dp))
            LinearProgressIndicator(
                progress = { if (done) 1f else progress.coerceAtLeast(0.02f) },
                color = if (done) SuccessGreen else WizardAccent,
                trackColor = WizardBgElevated,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Spacer(Modifier.height(16.dp))

        // Card
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 260.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(WizardBgCard)
                .border(1.dp, WizardBorderSubtle, RoundedCornerShape(16.dp))
                .padding(18.dp),
        ) {
            if (index < lastIndex) {
                val lesson = lessons[index]
                Kicker(TourKickers[index])
                Spacer(Modifier.height(12.dp))
                Text(lesson.title, color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(12.dp))
                Text(lesson.body, color = SecondaryText, fontSize = 15.sp, lineHeight = 21.sp)
                Spacer(Modifier.height(16.dp))
                ImportTourArt(index, Modifier.fillMaxWidth())
            } else {
                Kicker("READY")
                Spacer(Modifier.height(12.dp))
                ReadyCard(done, failed, counts, isReadOnly = setupMode == "browse", onKeepRunning = enter)
            }
            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                TextButton(
                    onClick = { index -= 1 },
                    enabled = index > 0,
                    modifier = Modifier.heightIn(min = 48.dp),
                ) {
                    Text("Back", color = if (index > 0) SecondaryText else Color.Transparent)
                }
                Spacer(Modifier.weight(1f))
                Pips(count = lastIndex + 1, index = index)
                Spacer(Modifier.weight(1f))
                if (index < lastIndex) {
                    TourButton("Next", enabled = true) { index += 1 }
                } else {
                    TourButton("Enter", enabled = done || failed, onClick = enter)
                }
            }
        }

        if (done && index < lastIndex) {
            Spacer(Modifier.height(16.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(SuccessGreen.copy(alpha = 0.12f))
                    .padding(12.dp),
            ) {
                Icon(Icons.Default.CheckCircle, contentDescription = null, tint = SuccessGreen, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    "Import done. Your notes are home.",
                    color = SuccessGreen,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.weight(1f),
                )
                TourButton("Jump in", enabled = true, onClick = enter)
            }
        }
    }
}

@Composable
private fun Kicker(text: String) {
    Text(text, color = WizardAccent, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
}

@Composable
private fun TourButton(text: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(WizardGradient, alpha = if (enabled) 1f else 0.4f)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 18.dp),
    ) {
        Text(text, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Pips(count: Int, index: Int) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.clearAndSetSemantics { contentDescription = "Card ${index + 1} of $count" },
    ) {
        repeat(count) { i ->
            Box(Modifier.size(6.dp).clip(CircleShape).background(if (i == index) WizardAccent else WizardBorderSubtle))
        }
    }
}

@Composable
private fun ReadyCard(
    done: Boolean,
    failed: Boolean,
    counts: Triple<Int, Int, Int>?,
    isReadOnly: Boolean,
    onKeepRunning: () -> Unit,
) {
    Text(
        when {
            done -> "Your notes are home"
            failed -> "The import stopped"
            else -> "Almost there"
        },
        color = PrimaryText,
        fontSize = 20.sp,
        fontWeight = FontWeight.SemiBold,
    )
    Spacer(Modifier.height(12.dp))
    if (failed) {
        Text(
            "Some of your notes may not be here yet. You can import again any time from Settings → Import.",
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
        )
    } else if (done) {
        Text("Everything we found is saved on this device.", color = SecondaryText, fontSize = 15.sp)
        counts?.let { (notes, likes, all) ->
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CountTile(notes, "notes", Modifier.weight(1f))
                CountTile(likes, "likes", Modifier.weight(1f))
                CountTile(all, "in all", Modifier.weight(1f))
            }
        }
        if (isReadOnly) {
            Spacer(Modifier.height(12.dp))
            Text("Read-only for now. Add your private key in Settings to post.", color = SecondaryText, fontSize = 13.sp)
        }
    } else {
        Text(
            "Still importing. That's normal for a long history, so you can wait here or keep it running in the background.",
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
        )
        TextButton(onClick = onKeepRunning, modifier = Modifier.heightIn(min = 48.dp)) {
            Text("Keep it running in the background", color = WizardAccent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun CountTile(value: Int, label: String, modifier: Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(WizardBgElevated)
            .padding(vertical = 10.dp)
            .semantics(mergeDescendants = true) {},
    ) {
        Text(NumberFormat.getIntegerInstance().format(value), color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text(label, color = Muted, fontSize = 12.sp)
    }
}
