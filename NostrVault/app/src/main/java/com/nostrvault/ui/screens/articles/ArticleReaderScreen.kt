package com.nostrvault.ui.screens

import com.nostrvault.ui.navigation.FloatingNavBarInset
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.material.icons.outlined.Share
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.data.model.ArticleHighlight
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.threadLink
import com.nostrvault.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArticleReaderScreen(
    onBack: () -> Unit,
    onProfileClick: (String) -> Unit,
    onComment: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    viewModel: ArticleReaderViewModel = hiltViewModel(),
) {
    val note by viewModel.note.collectAsState()
    val liked by viewModel.likedEventIds.collectAsState()
    val zapped by viewModel.zapped.collectAsState()
    val context = LocalContext.current
    var highlighting by remember { mutableStateOf(false) }
    var highlightContext by remember { mutableStateOf<String?>(null) }
    var showZapSheet by remember { mutableStateOf(false) }
    val zapSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    val isLoading by viewModel.isLoading.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val highlights by viewModel.highlights.collectAsState()
    val tally by viewModel.tally.collectAsState()
    val zappedSats by viewModel.zappedSats.collectAsState()
    // Back from composing a comment: ask again so it shows.
    var resumed by remember { mutableStateOf(0) }
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) resumed++
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    var shownHighlights by remember { mutableStateOf<List<ArticleHighlight>?>(null) }
    val highlightSheetState = rememberModalBottomSheetState()
    val commentOnHighlight: (ArticleHighlight) -> Unit = { h ->
        shownHighlights = null
        onComment(viewModel.prepareComment(h))
    }
    val colors = LocalNostrVaultColors.current

    Scaffold(
        containerColor = WindowBackground,
        topBar = {
            TopAppBar(
                title = { Text("Article", color = PrimaryText, fontSize = 17.sp) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back", tint = colors.primary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = WindowBackground),
            )
        },
    ) { padding ->
        val current = note
        if (current != null) {
            LaunchedEffect(current.id) { viewModel.loadHighlights(current) }
            LaunchedEffect(current.id, resumed) { if (resumed > 0) viewModel.loadEngagement(current) }
        }
        when {
            current != null -> ArticleBody(
                note = current,
                author = profiles[current.pubkey],
                onProfileClick = onProfileClick,
                actions = {
                    val isLiked = current.id in liked
                    ArticleActionBar(
                        liked = isLiked,
                        zapped = zapped,
                        // Your own like and zap count as soon as you make them,
                        // before a relay echoes them back.
                        likeCount = tally.likers.size + if (isLiked && viewModel.myPubkey !in tally.likers) 1 else 0,
                        commentCount = tally.commentCount,
                        zapSats = tally.zapSats + if (tally.zapSats == 0L) zappedSats else 0L,
                        highlighting = highlighting,
                        onLike = { viewModel.like(current) },
                        onComment = { onComment(current.id) },
                        onZap = { showZapSheet = true },
                        onHighlight = { highlighting = !highlighting },
                        onShare = {
                            val ref = HavenBridge.encodeNevent(current.id, current.pubkey, current.kind)
                            val link = ref?.let { threadLink(it) } ?: "nostr:${current.id}"
                            val title = ArticleMeta.from(current).title
                            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(android.content.Intent.EXTRA_TEXT, "$title\n$link")
                            }
                            context.startActivity(android.content.Intent.createChooser(intent, "Share Article"))
                        },
                    )
                },
                onHighlightBlock = if (highlighting) { text -> highlightContext = text } else null,
                highlights = highlights,
                profiles = profiles,
                onShowHighlights = { shownHighlights = it },
                onCommentHighlight = commentOnHighlight,
                tally = tally,
                onOpenComment = { onNoteClick(viewModel.prepareOpen(it)) },
                gatedArticles = viewModel.gatedArticles,
                modifier = Modifier
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp)
                    // Clear of the bottom bar, which a pushed article keeps.
                    .padding(bottom = FloatingNavBarInset.height.value),
            )
            isLoading -> Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.fillMaxSize().padding(padding),
            ) { CircularProgressIndicator(color = colors.primary) }
            else -> Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.fillMaxSize().padding(padding),
            ) {
                Text(
                    "That article is not in your vault, and no relay answered for it.",
                    color = SecondaryText,
                    fontSize = 14.sp,
                )
            }
        }
    }

    shownHighlights?.let { group ->
        ModalBottomSheet(
            onDismissRequest = { shownHighlights = null },
            sheetState = highlightSheetState,
            containerColor = WindowBackground,
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp)
                    .padding(bottom = 32.dp),
            ) {
                Text("Highlights", color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                group.forEach { h ->
                    HighlightRow(h, profiles[h.pubkey], onComment = { commentOnHighlight(h) })
                }
            }
        }
    }

    val target = note
    if (showZapSheet && target != null) {
        CustomZapSheet(
            sheetState = zapSheetState,
            defaultAmount = viewModel.defaultZapSats,
            onDismiss = { showZapSheet = false },
            onZap = { amount ->
                viewModel.zap(target, amount)
                showZapSheet = false
            },
        )
    }
    val passageContext = highlightContext
    if (passageContext != null && target != null) {
        HighlightDialog(
            initialPassage = passageContext,
            onDismiss = { highlightContext = null },
            onPublish = { passage, comment ->
                viewModel.publishHighlight(target, passage, passageContext, comment)
                highlightContext = null
                highlighting = false
            },
        )
    }
}
