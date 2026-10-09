package com.nostrvault.vaultguide

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.formatTimestamp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

private val CardSurface = Color(0xFF1F1F1F)
private val ChipSurface = Color(0xFF2E2E2E)
private val GoldLight = Color(0xFFFFE08A)
private val GoldMid = Color(0xFFF2B81F)
private val GoldDark = Color(0xFFC98A00)
private val GoldInk = Color(0xFF3A2A00)

/** What the profile card shows: loaded by the feed screen, which owns the services. */
data class ProfileCardData(
    val followingCount: Int? = null,
    /** Content and created_at (epoch seconds) of their latest notes, newest first. */
    val posts: List<Pair<String, Long>> = emptyList(),
    val loadingPosts: Boolean = true,
)

/**
 * The "Fill your feed" guide, drawn over the feed: its cards, the meter on
 * Post's row, and the sheets they open. What shows comes from
 * [FillYourVaultCoordinator.phase]; the rules are in [FillYourFeedGuide].
 * Design: OUTBOX/fill-your-vault-mockup.html (Tory). iOS: FillYourFeedOverlay.swift.
 *
 * [bottomInset] is Post's row above the nav bar. [onMeterHeight] reports the
 * open meter's height so Post rises above it and the feed scrolls clear.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FillYourFeedOverlay(
    profiles: Map<String, FeedProfile>,
    bottomInset: Dp,
    isFollowing: (String) -> Boolean,
    onToggleFollow: (String) -> Unit,
    onUnfollow: (String) -> Unit,
    loadProfileCard: suspend (String) -> ProfileCardData,
    onOpenFullProfile: (String) -> Unit,
) {
    Box(Modifier.fillMaxSize()) {
        val guide = FillYourVaultCoordinator
        val phase by guide.phase.collectAsState()
        val meterOn by guide.meterOn.collectAsState()
        val collapsed by guide.meterCollapsed.collectAsState()
        val meter by guide.meter.collectAsState()
        val celebrate by guide.celebrateVaultMaster.collectAsState()
        val cardPubkey by guide.profileCardPubkey.collectAsState()
        val reduceMotion = rememberReduceMotion()
        var showingPicks by remember { mutableStateOf(false) }
        val bolt = remember { Animatable(-0.2f) }
        var boltRunning by remember { mutableStateOf(false) }

        LaunchedEffect(celebrate) {
            if (!celebrate) return@LaunchedEffect
            guide.meterCollapsed.value = false
            if (reduceMotion) {
                delay(700)
            } else {
                boltRunning = true
                bolt.snapTo(-0.2f)
                bolt.animateTo(1.2f, tween(900, easing = CubicBezierEasing(0.5f, 0f, 0.3f, 1f)))
                boltRunning = false
                delay(500)
            }
            guide.showReadyCard()
        }

        val dims = phase == FillYourFeedPhase.INTRO || phase == FillYourFeedPhase.READY
        if (dims) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)).clickable(enabled = false) {})
        }

        Box(
            Modifier
                .align(if (phase == FillYourFeedPhase.HINT) Alignment.TopCenter else Alignment.Center)
                .padding(horizontal = 16.dp)
                .padding(top = if (phase == FillYourFeedPhase.HINT) 72.dp else 12.dp, bottom = bottomInset + 64.dp)
                .widthIn(max = 420.dp),
        ) {
            when (phase) {
                FillYourFeedPhase.INTRO -> IntroCard()
                FillYourFeedPhase.TOPICS -> TopicsCard()
                FillYourFeedPhase.HINT -> HintCard()
                FillYourFeedPhase.READY -> ReadyCard(profiles)
                FillYourFeedPhase.OFF, FillYourFeedPhase.BROWSING -> Unit
            }
        }

        if (FillYourFeedGuide.showsMeter(phase, meterOn)) {
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .padding(bottom = bottomInset),
            ) {
                if (collapsed) {
                    LaunchedEffect(Unit) { guide.meterHeight.value = 0.dp }
                    MeterPill(meter, Modifier.align(Alignment.CenterStart)) { guide.meterCollapsed.value = false }
                } else {
                    val density = LocalDensity.current
                    MeterBar(
                        meter = meter,
                        profiles = profiles,
                        bolt = if (boltRunning) bolt.value else null,
                        modifier = Modifier.onSizeChanged { guide.meterHeight.value = with(density) { it.height.toDp() } },
                        onOpen = { showingPicks = true },
                        onCollapse = { guide.meterCollapsed.value = true },
                    )
                }
            }
        }

        if (showingPicks) {
            ModalBottomSheet(
                onDismissRequest = { showingPicks = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false),
                containerColor = CardSurface,
            ) {
                PicksSheet(meter, profiles, onUnfollow, onDone = { showingPicks = false }, onHide = {
                    showingPicks = false
                    guide.closeGuide()
                })
            }
        }

        cardPubkey?.let { pubkey ->
            ModalBottomSheet(
                onDismissRequest = { guide.profileCardPubkey.value = null },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = CardSurface,
            ) {
                ProfileCard(
                    pubkey = pubkey,
                    profile = profiles[pubkey],
                    following = isFollowing(pubkey),
                    load = loadProfileCard,
                    onToggleFollow = {
                        val was = isFollowing(pubkey)
                        onToggleFollow(pubkey)
                        // A new follow fills the meter: close the card so it shows.
                        if (!was) guide.profileCardPubkey.value = null
                    },
                    onFullProfile = {
                        guide.profileCardPubkey.value = null
                        onOpenFullProfile(pubkey)
                    },
                )
            }
        }
    }
}

@Composable
private fun rememberReduceMotion(): Boolean {
    val context = androidx.compose.ui.platform.LocalContext.current
    return remember {
        android.provider.Settings.Global.getFloat(
            context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f,
        ) == 0f
    }
}

// ── Card chrome (Ted's TutorialStage card) ─────────────────────────

@Composable
private fun GuideCard(
    step: Int? = null,
    border: Color = LocalNostrVaultColors.current.primary,
    onSkip: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(18.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .shadow(16.dp, shape)
            .background(CardSurface, shape)
            .border(1.dp, border.copy(alpha = 0.6f), shape)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (step != null || onSkip != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (step != null) Text("$step of 3", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                if (onSkip != null) {
                    TextButton(onClick = onSkip) {
                        Text("Skip", color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
        content()
    }
}

@Composable
private fun CardTitle(text: String, color: Color = PrimaryText, center: Boolean = false) {
    Text(
        text,
        color = color,
        fontSize = 20.sp,
        fontWeight = FontWeight.Bold,
        textAlign = if (center) TextAlign.Center else TextAlign.Start,
        modifier = (if (center) Modifier.fillMaxWidth() else Modifier).semantics { heading() },
    )
}

@Composable
private fun CardBody(text: String) {
    Text(text, color = PrimaryText.copy(alpha = 0.85f), fontSize = 15.sp, lineHeight = 21.sp)
}

@Composable
private fun PrimaryButton(
    text: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    container: Color = LocalNostrVaultColors.current.primary,
    content: Color = Color.White,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.heightIn(min = 48.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = container, contentColor = content,
            disabledContainerColor = container.copy(alpha = 0.4f), disabledContentColor = content.copy(alpha = 0.6f),
        ),
    ) { Text(text, fontWeight = FontWeight.SemiBold, fontSize = 16.sp) }
}

// ── 1. Intro ───────────────────────────────────────────────────────

@Composable
private fun IntroCard() {
    val guide = FillYourVaultCoordinator
    GuideCard(step = 1, onSkip = guide::closeGuide) {
        CardTitle("Fill your feed")
        WebOfTrustDiagram(Modifier.fillMaxWidth().height(132.dp))
        CardBody("Nostr starts empty. No algorithm picks for you. Follow a few people, and the people they follow become your web of trust. It fills your feed and filters out spam.")
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = guide::closeGuide, modifier = Modifier.heightIn(min = 48.dp)) {
                Text("Not now", color = SecondaryText, fontSize = 16.sp)
            }
            PrimaryButton("Let's fill it", onClick = guide::beginFilling)
        }
    }
}

@Composable
private fun WebOfTrustDiagram(modifier: Modifier) {
    val primary = LocalNostrVaultColors.current.primary
    val measurer = rememberTextMeasurer()
    val colors = listOf(Color(0xFFC2410C), Color(0xFF0E7490), Color(0xFF7C3AED), Color(0xFF15803D), Color(0xFFB91C1C))
    Canvas(modifier.semantics { contentDescription = "You, connected to the people you follow, connected to the people they follow." }) {
        val d = density
        val c = Offset(size.width / 2, size.height / 2 - 6 * d)
        val mids = (0 until 5).map { k ->
            val a = -PI / 2 + k * 2 * PI / 5
            Offset(c.x + 52 * d * cos(a).toFloat(), c.y + 44 * d * sin(a).toFloat())
        }
        for (p in mids) {
            val base = atan2(p.y - c.y, p.x - c.x)
            for (j in -1..1) {
                val a = base + j * 0.38f
                val o = Offset(c.x + 120 * d * cos(a), c.y + 52 * d * sin(a))
                drawLine(Color.White.copy(alpha = 0.18f), p, o, strokeWidth = 1 * d)
                drawCircle(Color(0xFF5A5A60), 5 * d, o)
            }
        }
        for (p in mids) drawLine(primary.copy(alpha = 0.7f), c, p, strokeWidth = 1.5f * d)
        mids.forEachIndexed { k, p ->
            drawCircle(colors[k], 11 * d, p)
            drawCircle(CardSurface, 11 * d, p, style = Stroke(2 * d))
        }
        drawCircle(primary, 17 * d, c)
        drawCircle(CardSurface, 17 * d, c, style = Stroke(3 * d))
        val you = measurer.measure("You", TextStyle(color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold))
        drawText(you, topLeft = Offset(c.x - you.size.width / 2, c.y - you.size.height / 2))
        val small = TextStyle(color = SecondaryText, fontSize = 10.sp)
        val l = measurer.measure("your follows", small)
        drawText(l, topLeft = Offset(size.width / 2 - 100 * d - l.size.width / 2, size.height - l.size.height))
        val r = measurer.measure("their follows", small)
        drawText(r, topLeft = Offset(size.width / 2 + 100 * d - r.size.width / 2, size.height - r.size.height))
    }
}

// ── 2. Topics ──────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TopicsCard() {
    val guide = FillYourVaultCoordinator
    val selected = remember { mutableStateListOf<String>().apply { addAll(guide.followedTopics()) } }
    var showingMore by remember { mutableStateOf(false) }
    GuideCard(step = 2, onSkip = guide::closeGuide) {
        CardTitle("What are you into?")
        CardBody("Pick a few topics. You'll see posts about them from everyone, so you can find people to follow.")
        Column(Modifier.heightIn(max = 300.dp).verticalScroll(rememberScrollState())) {
            TopicChips(VaultTopics.starter + selected.filter { it !in VaultTopics.starter }, selected, onMore = { showingMore = true })
        }
        PrimaryButton(
            FillYourFeedGuide.showPostsTitle(selected.size),
            modifier = Modifier.fillMaxWidth(),
            enabled = selected.isNotEmpty(),
        ) { guide.showPosts(selected.toList()) }
    }
    if (showingMore) {
        ModalBottomSheet(
            onDismissRequest = { showingMore = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = CardSurface,
        ) { MoreTopicsSheet(selected) { showingMore = false } }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TopicChips(topics: List<String>, selected: MutableList<String>, onMore: (() -> Unit)? = null) {
    val primary = LocalNostrVaultColors.current.primary
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (topic in topics) {
            val on = topic in selected
            Box(
                Modifier
                    .heightIn(min = 40.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .background(if (on) primary else ChipSurface)
                    .border(1.dp, if (on) primary else Color.White.copy(alpha = 0.1f), RoundedCornerShape(20.dp))
                    .clickable(role = Role.Checkbox) { if (on) selected.remove(topic) else selected.add(topic) }
                    .semantics { this.selected = on }
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("#$topic", color = PrimaryText, fontSize = 15.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal)
            }
        }
        if (onMore != null) {
            Box(
                Modifier
                    .heightIn(min = 40.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .drawWithContent {
                        drawContent()
                        drawRoundRect(
                            primary,
                            cornerRadius = androidx.compose.ui.geometry.CornerRadius(20.dp.toPx()),
                            style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 8f))),
                        )
                    }
                    .clickable(role = Role.Button, onClick = onMore)
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) { Text("More topics…", color = primary, fontSize = 15.sp) }
        }
    }
}

@Composable
private fun MoreTopicsSheet(selected: MutableList<String>, onDone: () -> Unit) {
    var typed by rememberSaveable { mutableStateOf("") }
    fun add() {
        val tag = VaultTopics.normalize(typed) ?: return
        if (tag !in selected) selected.add(tag)
        typed = ""
    }
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CardTitle("More topics")
        Text("Or type any hashtag.", color = SecondaryText, fontSize = 15.sp)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = typed,
                onValueChange = { typed = it },
                placeholder = { Text("#anything") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done, autoCorrectEnabled = false),
                keyboardActions = KeyboardActions(onDone = { add() }),
                modifier = Modifier.weight(1f).semantics { contentDescription = "Type a hashtag" },
            )
            PrimaryButton("Add", enabled = VaultTopics.normalize(typed) != null) { add() }
        }
        TopicChips(VaultTopics.more + selected.filter { it !in VaultTopics.starter && it !in VaultTopics.more }, selected)
        PrimaryButton("Done", modifier = Modifier.fillMaxWidth(), onClick = onDone)
    }
}

// ── 3. Hint ────────────────────────────────────────────────────────

@Composable
private fun HintCard() {
    val guide = FillYourVaultCoordinator
    GuideCard(step = 3, onSkip = guide::closeGuide) {
        CardTitle("Find people you like")
        CardBody("Tap anyone to see their profile and posts first. When you like what you see, follow them. Each follow fills a spot down by the tabs. Five builds your web of trust.")
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            PrimaryButton("Got it", onClick = guide::dismissHint)
        }
    }
}

// ── 4. Your web of trust is built ──────────────────────────────────

/** One card at 5 follows: the web of trust is built, then on to Discover
 *  and the Feeds tutorial. iOS: ReadyCard in FillYourFeedOverlay.swift. */
@Composable
private fun ReadyCard(profiles: Map<String, FeedProfile>) {
    val guide = FillYourVaultCoordinator
    val meter by guide.meter.collectAsState()
    var reach by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(Unit) { reach = guide.countExtendedNetwork() }
    GuideCard(border = GoldMid) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { Box(
            Modifier
                .size(60.dp)
                .shadow(12.dp, CircleShape, ambientColor = GoldMid, spotColor = GoldMid)
                .background(Brush.radialGradient(listOf(GoldLight, GoldMid, GoldDark)), CircleShape),
            contentAlignment = Alignment.Center,
        ) { Icon(NostrVaultIcons.Zap, contentDescription = null, tint = GoldInk, modifier = Modifier.size(32.dp)) } }
        CardTitle(FillYourFeedGuide.READY_TITLE, color = GoldLight, center = true)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
            meter.recent.forEachIndexed { i, pk ->
                Box(Modifier.offset(x = (-10 * i).dp).border(3.dp, CardSurface, CircleShape)) {
                    AvatarImage(url = profiles[pk]?.pictureURL, pubkey = pk, size = 44.dp, displayName = profiles[pk]?.bestName)
                }
            }
        }
        Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalAlignment = Alignment.CenterHorizontally) {
            val r = reach
            if (r != null && r > 0) {
                Text("%,d".format(r), color = PrimaryText, fontSize = 30.sp, fontWeight = FontWeight.Bold)
                Text("people your ${meter.count} follows bring into your web of trust", color = SecondaryText, fontSize = 13.sp, textAlign = TextAlign.Center)
            } else {
                Text("Counting the people your follows bring in…", color = SecondaryText, fontSize = 13.sp)
            }
        }
        Text(
            "Find more people on Discover. It shows posts from the people your follows follow.",
            color = PrimaryText.copy(alpha = 0.85f), fontSize = 15.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
        )
        PrimaryButton(
            FillYourFeedGuide.READY_BUTTON, modifier = Modifier.fillMaxWidth(),
            container = GoldMid, content = GoldInk, onClick = guide::goToDiscover,
        )
    }
}

// ── Meter ──────────────────────────────────────────────────────────

@Composable
private fun MeterBar(
    meter: VaultMeter,
    profiles: Map<String, FeedProfile>,
    bolt: Float?,
    modifier: Modifier,
    onOpen: () -> Unit,
    onCollapse: () -> Unit,
) {
    val gold = meter.stage == VaultMeter.Stage.MASTER
    val compact = androidx.compose.ui.platform.LocalConfiguration.current.fontScale >= 1.3f
    val shape = RoundedCornerShape(26.dp)
    Box(
        modifier
            .fillMaxWidth()
            .shadow(if (gold) 12.dp else 8.dp, shape, ambientColor = if (gold) GoldMid else Color.Black, spotColor = if (gold) GoldMid else Color.Black)
            .background(Color(0xF02A2A2D), shape)
            .border(1.dp, if (gold) GoldMid.copy(alpha = 0.75f) else Color.White.copy(alpha = 0.1f), shape)
            .clip(shape)
            .clickable(role = Role.Button, onClickLabel = "Open your picks", onClick = onOpen)
            .semantics(mergeDescendants = true) { contentDescription = meter.accessibilityText },
    ) {
        Row(
            Modifier.padding(start = 14.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            MeterSlots(meter, profiles, gold)
            Column(Modifier.weight(1f)) {
                Text(
                    FillYourFeedGuide.meterTitle(meter, compact),
                    color = if (gold) GoldLight else PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (!compact) {
                    Text(FillYourFeedGuide.meterSubtitle(meter), color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            IconButton(onClick = onCollapse, modifier = Modifier.size(48.dp)) {
                Icon(NostrVaultIcons.ChevronDown, contentDescription = "Fold the meter down", tint = SecondaryText)
            }
        }
        if (bolt != null) {
            Canvas(Modifier.matchParentSize()) {
                val x = size.width * bolt
                val flash = if (bolt > 0.6f) ((1.2f - bolt) * 1.5f).coerceIn(0f, 1f) else 0f
                drawRect(Brush.radialGradient(listOf(GoldLight.copy(alpha = 0.55f * flash), Color.Transparent)))
                val h = size.height
                val path = androidx.compose.ui.graphics.Path().apply {
                    moveTo(x - 26f, h * 0.55f); lineTo(x - 6f, h * 0.35f); lineTo(x - 10f, h * 0.55f)
                    lineTo(x + 26f, h * 0.30f); lineTo(x + 6f, h * 0.60f); lineTo(x + 10f, h * 0.45f); close()
                }
                drawPath(path, GoldLight)
                drawPath(path, GoldMid, style = Stroke(3f))
            }
        }
    }
}

@Composable
private fun MeterSlots(meter: VaultMeter, profiles: Map<String, FeedProfile>, gold: Boolean) {
    val row = meter.slots
    val size = 32.dp
    val overlap = 6.dp
    val people = meter.recent.takeLast(row)
    Row(Modifier.semantics { }) {
        for (i in 0 until row) {
            val slot = Modifier.offset(x = -overlap * i).size(size)
            if (i < people.size) {
                val pk = people[i]
                Box(slot.border(2.dp, if (gold) GoldMid else Color(0xFF141414), CircleShape).clip(CircleShape)) {
                    AvatarImage(url = profiles[pk]?.pictureURL, pubkey = pk, size = size, displayName = profiles[pk]?.bestName)
                }
            } else {
                // A ring in the meter's colour, like the photos', so
                // overlapping slots don't cross their dashes.
                Canvas(slot) {
                    val ring = 2.dp.toPx()
                    drawCircle(Color(0xFF141414))
                    drawCircle(Color(0xFF1F1F1F), radius = this.size.minDimension / 2 - ring)
                    drawCircle(
                        Color.White.copy(alpha = 0.35f),
                        radius = this.size.minDimension / 2 - ring - 0.75.dp.toPx(),
                        style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f))),
                    )
                }
            }
        }
    }
}

@Composable
private fun MeterPill(meter: VaultMeter, modifier: Modifier, onClick: () -> Unit) {
    val primary = LocalNostrVaultColors.current.primary
    val gold = meter.stage == VaultMeter.Stage.MASTER
    val ring = if (gold) GoldMid else primary
    val shape = RoundedCornerShape(24.dp)
    Row(
        modifier
            .heightIn(min = 48.dp)
            .shadow(8.dp, shape)
            .background(Color(0xF02A2A2D), shape)
            .border(1.dp, if (gold) GoldMid.copy(alpha = 0.75f) else Color.White.copy(alpha = 0.1f), shape)
            .clip(shape)
            .clickable(role = Role.Button, onClickLabel = "Open the meter", onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = meter.accessibilityText }
            .padding(start = 8.dp, end = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.matchParentSize()) {
                val w = 3.dp.toPx()
                drawCircle(Color.White.copy(alpha = 0.18f), style = Stroke(w))
                drawArc(ring, -90f, 360f * FillYourFeedGuide.ringFraction(meter), false, style = Stroke(w, cap = StrokeCap.Round),
                    topLeft = Offset(w / 2, w / 2), size = androidx.compose.ui.geometry.Size(size.width - w, size.height - w))
            }
            Icon(NostrVaultIcons.Zap, contentDescription = null, tint = ring, modifier = Modifier.size(14.dp))
        }
        Text(FillYourFeedGuide.pillText(meter), color = if (gold) GoldLight else PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

// ── Picks sheet (tap the meter) ────────────────────────────────────

@Composable
private fun PicksSheet(
    meter: VaultMeter,
    profiles: Map<String, FeedProfile>,
    onUnfollow: (String) -> Unit,
    onDone: () -> Unit,
    onHide: () -> Unit,
) {
    val primary = LocalNostrVaultColors.current.primary
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CardTitle("Your feed")
        Text("Your web of trust is the people you follow, plus the people they follow. Nobody else picks it.", color = SecondaryText, fontSize = 15.sp)
        Text("FOLLOWING (${meter.count})", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        if (meter.recent.isEmpty()) Text("Nobody yet. Tap someone in the feed to see their profile.", color = SecondaryText, fontSize = 15.sp)
        for (pk in meter.recent.reversed()) {
            val p = profiles[pk]
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                AvatarImage(url = p?.pictureURL, pubkey = pk, size = 40.dp, displayName = p?.bestName)
                Column(Modifier.weight(1f)) {
                    Text(p?.bestName ?: pk.take(10), color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                    p?.nip05?.takeIf { it.isNotBlank() }?.let { Text(it, color = SecondaryText, fontSize = 13.sp, maxLines = 1) }
                }
                TextButton(onClick = { onUnfollow(pk) }, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text("Unfollow", color = primary, fontWeight = FontWeight.SemiBold)
                }
            }
            HorizontalDivider(color = Color.White.copy(alpha = 0.1f))
        }
        PrimaryButton("Done", modifier = Modifier.fillMaxWidth(), onClick = onDone)
        TextButton(onClick = onHide, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
            Text("Hide the meter", color = SecondaryText, fontSize = 16.sp)
        }
    }
}

// ── Profile card ───────────────────────────────────────────────────

/**
 * "Look before you follow": bio, how many people they follow, their 3 latest
 * posts and Follow. Follow never waits on the posts. iOS: FeedProfileCard.
 */
@Composable
private fun ProfileCard(
    pubkey: String,
    profile: FeedProfile?,
    following: Boolean,
    load: suspend (String) -> ProfileCardData,
    onToggleFollow: () -> Unit,
    onFullProfile: () -> Unit,
) {
    val primary = LocalNostrVaultColors.current.primary
    var data by remember(pubkey) { mutableStateOf(ProfileCardData()) }
    LaunchedEffect(pubkey) { data = load(pubkey) }
    val name = profile?.bestName ?: pubkey.take(10)
    // Half the screen at most, so the sheet opens at half height with
    // "See full profile" in view; the posts scroll above it.
    val maxHeight = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp.dp * 0.5f
    Column(Modifier.fillMaxWidth().heightIn(max = maxHeight)) {
    Column(
        Modifier.fillMaxWidth().weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 64.dp, displayName = profile?.bestName)
            Column {
                Text(name, color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.Bold, maxLines = 2, modifier = Modifier.semantics { heading() })
                profile?.nip05?.takeIf { it.isNotBlank() }?.let { Text(it, color = SecondaryText, fontSize = 15.sp, maxLines = 1) }
            }
        }
        profile?.about?.trim()?.takeIf { it.isNotEmpty() }?.let {
            Text(it, color = PrimaryText, fontSize = 15.sp, maxLines = 6, overflow = TextOverflow.Ellipsis)
        }
        data.followingCount?.let { Text("$it following", color = SecondaryText, fontSize = 13.sp) }
        PrimaryButton(
            if (following) "✓ Following" else "Follow",
            modifier = Modifier.fillMaxWidth().semantics { contentDescription = if (following) "Following $name. Tap to unfollow." else "Follow $name" },
            container = if (following) Color(0xFF404040) else primary,
            onClick = onToggleFollow,
        )
        Text("RECENT POSTS", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 6.dp))
        if (data.posts.isEmpty()) {
            Text(if (data.loadingPosts) "Loading posts…" else "No recent posts found.", color = SecondaryText, fontSize = 15.sp)
        }
        for ((content, at) in data.posts) {
            Column(Modifier.padding(vertical = 6.dp)) {
                Text(content, color = PrimaryText, fontSize = 15.sp, maxLines = 6, overflow = TextOverflow.Ellipsis)
                Text(formatTimestamp(at), color = SecondaryText, fontSize = 12.sp)
            }
            HorizontalDivider(color = Color.White.copy(alpha = 0.1f))
        }
    }
        // Pinned under the scrolling part, so the half-height card never cuts it off.
        TextButton(onClick = onFullProfile, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(bottom = 8.dp)) {
            Text("See full profile", color = primary, fontWeight = FontWeight.SemiBold)
        }
    }
}
