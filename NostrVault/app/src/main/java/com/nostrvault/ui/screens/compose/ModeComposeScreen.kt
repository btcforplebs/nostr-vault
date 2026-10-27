package com.nostrvault.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.data.model.LongFormDraft
import com.nostrvault.ui.theme.*
import com.nostrvault.ui.components.ProseKeyboardOptions

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModeComposeScreen(
    onDone: () -> Unit,
    viewModel: ModeComposeViewModel = hiltViewModel(),
) {
    val colors = LocalNostrVaultColors.current
    val busy by viewModel.busy.collectAsState()
    val status by viewModel.status.collectAsState()
    val error by viewModel.error.collectAsState()
    val clip by viewModel.clip.collectAsState()
    val cover by viewModel.cover.collectAsState()

    var title by rememberSaveable { mutableStateOf("") }
    var summary by rememberSaveable { mutableStateOf("") }
    var body by rememberSaveable { mutableStateOf("") }
    var prepTime by rememberSaveable { mutableStateOf("") }
    var cookTime by rememberSaveable { mutableStateOf("") }
    var servings by rememberSaveable { mutableStateOf("") }
    var ingredients by rememberSaveable { mutableStateOf("") }
    var directions by rememberSaveable { mutableStateOf("") }
    var categories by rememberSaveable { mutableStateOf("") }

    // The X is disabled while busy; system back would otherwise pop the
    // route and cancel the upload or post partway through.
    BackHandler(enabled = busy) {}

    val kind = viewModel.kind
    if (kind == ModeComposerKind.LISTING) {
        MarketplaceSellScreen(onDone = onDone, viewModel = viewModel)
        return
    }
    if (kind == ModeComposerKind.POLL) {
        PollComposeScreen(onDone = onDone, viewModel = viewModel)
        return
    }
    val canPost = when (kind) {
        ModeComposerKind.DIVINE -> clip != null
        ModeComposerKind.ARTICLE -> title.isNotBlank() && body.isNotBlank()
        ModeComposerKind.RECIPE -> title.isNotBlank() &&
            LongFormDraft.lines(ingredients).isNotEmpty() && LongFormDraft.lines(directions).isNotEmpty()
        ModeComposerKind.LISTING, ModeComposerKind.POLL -> false
    }

    // Saved drafts, for articles and recipes (a diVine has none).
    val drafts = viewModel.drafts
    var showingDrafts by remember { mutableStateOf(false) }
    var confirmingCancel by remember { mutableStateOf(false) }
    val isRecipe = kind == ModeComposerKind.RECIPE
    val currentDraft = ComposerDraft(
        kind = if (isRecipe) ComposerDraft.Kind.RECIPE else ComposerDraft.Kind.ARTICLE,
        title = title,
        summary = summary,
        body = body,
        coverMime = viewModel.currentCoverMime(),
        prepTime = if (isRecipe) prepTime else "",
        cookTime = if (isRecipe) cookTime else "",
        servings = if (isRecipe) servings else "",
        ingredients = if (isRecipe) ingredients else "",
        directions = if (isRecipe) directions else "",
        categories = if (isRecipe) categories else "",
    )
    if (drafts != null) AutosaveComposerDraft(drafts, currentDraft, viewModel.coverFile)

    fun openDraft(saved: ComposerDraft) {
        val keeper = drafts ?: return
        keeper.saveNow(currentDraft, viewModel.coverFile)
        viewModel.showDraftCover(keeper.open(saved), saved.coverMime)
        title = saved.title
        summary = saved.summary
        body = saved.body
        prepTime = saved.prepTime
        cookTime = saved.cookTime
        servings = saved.servings
        ingredients = saved.ingredients
        directions = saved.directions
        categories = saved.categories
    }

    // Cancel asks to keep anything typed; an untouched form just closes.
    fun cancelTapped() {
        val keeper = drafts ?: return onDone()
        if (currentDraft.hasContent || cover != null) {
            confirmingCancel = true
        } else {
            keeper.finish()
            onDone()
        }
    }
    BackHandler(enabled = !busy && drafts != null) { cancelTapped() }

    fun submit() {
        when (kind) {
            ModeComposerKind.DIVINE -> viewModel.postDivine(title, body, onDone)
            ModeComposerKind.ARTICLE -> viewModel.publishLongForm(
                LongFormDraft(title = title, summary = summary, body = body), onDone)
            ModeComposerKind.RECIPE -> viewModel.publishLongForm(
                LongFormDraft(
                    title = title, summary = summary, body = body,
                    recipe = LongFormDraft.Recipe(prepTime, cookTime, servings, ingredients, directions, categories),
                ), onDone)
            ModeComposerKind.LISTING, ModeComposerKind.POLL -> Unit
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        when (kind) {
                            ModeComposerKind.DIVINE -> "New diVine"
                            ModeComposerKind.ARTICLE -> "New article"
                            ModeComposerKind.RECIPE -> "New recipe"
                            ModeComposerKind.LISTING -> "Sell something"
                            ModeComposerKind.POLL -> "New poll"
                        }
                    )
                },
                navigationIcon = {
                    IconButton(onClick = { cancelTapped() }, enabled = !busy) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Cancel")
                    }
                },
                actions = {
                    Button(
                        onClick = { submit() },
                        enabled = canPost && !busy,
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                        shape = RoundedCornerShape(20.dp),
                        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
                    ) {
                        if (busy) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = PrimaryText)
                        } else {
                            Text(
                                if (kind == ModeComposerKind.DIVINE) "Post" else "Publish",
                                fontWeight = FontWeight.SemiBold,
                                color = PrimaryText,
                            )
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
            if (kind == ModeComposerKind.DIVINE) {
                DivineVideoArea(clip = clip, busy = busy, onPicked = viewModel::loadClip)
                if (clip != null) {
                    Field(title, { title = it }, "Title (optional)")
                    Field(body, { body = it }, "Caption (optional) — #tags work", minLines = 2)
                }
            } else {
                drafts?.let { ComposerDraftsRow(it) { showingDrafts = true } }
                CoverPicker(cover = cover, onPicked = viewModel::setCover)
                Field(title, { title = it }, "Title")
                Field(summary, { summary = it },
                    if (kind == ModeComposerKind.RECIPE) "Short description" else "Summary (optional)")
                if (kind == ModeComposerKind.RECIPE) {
                    Field(prepTime, { prepTime = it }, "Prep time, e.g. 15 min")
                    Field(cookTime, { cookTime = it }, "Cook time, e.g. 30 min")
                    Field(servings, { servings = it }, "Servings")
                    Field(ingredients, { ingredients = it }, "Ingredients, one per line", minLines = 5)
                    Field(directions, { directions = it }, "Directions, one step per line", minLines = 6)
                    Field(body, { body = it }, "Chef's notes (optional)", minLines = 3)
                    Field(categories, { categories = it }, "Categories, comma separated")
                } else {
                    Field(body, { body = it }, "Article. Markdown works: # headings, **bold**, - lists", minLines = 12)
                }
            }
            status?.let {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.primary)
                    Text(it, color = SecondaryText, fontSize = 13.sp)
                }
            }
            error?.let { Text(it, color = Color(0xFFFF453A), fontSize = 13.sp) }
        }
    }

    if (drafts != null && showingDrafts) {
        ComposerDraftsSheet(drafts, viewModel.draftStore, onSelect = ::openDraft, onDismiss = { showingDrafts = false })
    }
    if (drafts != null && confirmingCancel) {
        SaveComposerDraftPrompt(
            noun = if (isRecipe) "recipe" else "article",
            editsSavedDraft = drafts.editsSavedDraft,
            onSave = {
                confirmingCancel = false
                drafts.saveNow(currentDraft, viewModel.coverFile)
                onDone()
            },
            onDiscard = {
                confirmingCancel = false
                drafts.discard()
                onDone()
            },
            onKeepEditing = { confirmingCancel = false },
        )
    }
}

@Composable
private fun Field(value: String, onChange: (String) -> Unit, label: String, minLines: Int = 1) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        minLines = minLines,
        singleLine = minLines == 1,
        keyboardOptions = ProseKeyboardOptions,
        modifier = Modifier.fillMaxWidth(),
    )
}
