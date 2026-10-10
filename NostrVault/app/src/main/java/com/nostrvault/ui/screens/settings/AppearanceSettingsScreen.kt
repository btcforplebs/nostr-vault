package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.FeedLanguage
import com.nostrvault.service.FeedService
import com.nostrvault.service.NoteTranslationPolicy
import com.nostrvault.service.NoteTranslator
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.components.deviceLanguageTags
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Appearance settings: text size, reaction emoji, zaps-only, tab bar animation,
 * and the Translate button on posts.
 * The theme-colour picker and OLED toggle were removed — the app has one
 * appearance: OLED black with the orange accent.
 */

@HiltViewModel
class AppearanceViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val feedService: FeedService,
    private val noteTranslator: NoteTranslator,
    private val pendingPostManager: PendingPostManager,
) : ViewModel() {

    /** How long posts wait before going out: 0 (Off), 5 or 10 seconds. */
    val sendDelaySeconds = pendingPostManager.sendDelaySeconds

    fun setSendDelaySeconds(seconds: Int) = pendingPostManager.setSendDelaySeconds(seconds)

    /** The Translate button under notes in another language. */
    val showTranslateButton = configStore.config
        .map { it.showTranslateButton }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), configStore.config.value.showTranslateButton)

    /** The language notes translate into, with an unset choice resolved to the device's. */
    val translateTarget = configStore.config
        .map { resolveTarget(it.translateTargetLanguage) }
        .stateIn(
            viewModelScope,
            SharingStarted.WhileSubscribed(5000),
            resolveTarget(configStore.config.value.translateTargetLanguage),
        )

    /** "Translate to" choices: device languages first, only what ML Kit can translate into. */
    val translateTargets: List<String> by lazy {
        NoteTranslationPolicy.pickerList(deviceLanguageTags(), noteTranslator.supportedLanguages)
    }

    private fun resolveTarget(saved: String): String =
        NoteTranslationPolicy.target(saved, deviceLanguageTags(), noteTranslator.supportedLanguages)

    fun setShowTranslateButton(on: Boolean) {
        configStore.update { it.copy(showTranslateButton = on) }
    }

    fun setTranslateTarget(code: String) {
        configStore.update { it.copy(translateTargetLanguage = code) }
    }


    private val _textScale = MutableStateFlow(1.0f)
    val textScale = _textScale.asStateFlow()


    private val _defaultEmoji = MutableStateFlow("+")
    val defaultEmoji = _defaultEmoji.asStateFlow()

    private val _zapsOnly = MutableStateFlow(false)
    val zapsOnly = _zapsOnly.asStateFlow()

    private val _disableTabBarAnimation = MutableStateFlow(false)
    val disableTabBarAnimation = _disableTabBarAnimation.asStateFlow()

    private val _compactLines = MutableStateFlow(FeedLineLimits.DEFAULT_COMPACT)
    val compactLines = _compactLines.asStateFlow()

    private val _threadedLines = MutableStateFlow(FeedLineLimits.DEFAULT_THREADED)
    val threadedLines = _threadedLines.asStateFlow()

    val showNewPostsPill = configStore.config
        .map { it.showNewPostsPill }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), configStore.config.value.showNewPostsPill)

    fun setShowNewPostsPill(on: Boolean) {
        configStore.update { it.copy(showNewPostsPill = on) }
    }

    init {
        val config = configStore.config.value
        _compactLines.value = config.compactLineLimit.coerceIn(FeedLineLimits.RANGE)
        _threadedLines.value = config.threadedLineLimit.coerceIn(FeedLineLimits.RANGE)
        _textScale.value = config.textSizeScale
        _defaultEmoji.value = config.defaultReactionEmoji
        _zapsOnly.value = config.zapsOnlyMode
        _disableTabBarAnimation.value = config.disableTabBarAnimation
    }


    fun setTextScale(scale: Float) {
        _textScale.value = scale
        viewModelScope.launch {
            configStore.update { it.copy(textSizeScale = scale) }
        }
    }

    fun setDefaultEmoji(emoji: String) {
        _defaultEmoji.value = emoji
        viewModelScope.launch {
            configStore.update { it.copy(defaultReactionEmoji = emoji) }
        }
    }

    fun toggleZapsOnly(enabled: Boolean) {
        _zapsOnly.value = enabled
        viewModelScope.launch {
            configStore.update { it.copy(zapsOnlyMode = enabled) }
        }
    }

    fun setCompactLines(lines: Int) {
        val value = lines.coerceIn(FeedLineLimits.RANGE)
        _compactLines.value = value
        viewModelScope.launch { configStore.update { it.copy(compactLineLimit = value) } }
    }

    fun setThreadedLines(lines: Int) {
        val value = lines.coerceIn(FeedLineLimits.RANGE)
        _threadedLines.value = value
        viewModelScope.launch { configStore.update { it.copy(threadedLineLimit = value) } }
    }

    fun toggleTabBarAnimation(disabled: Boolean) {
        _disableTabBarAnimation.value = disabled
        viewModelScope.launch {
            configStore.update { it.copy(disableTabBarAnimation = disabled) }
            // If the bar is currently condensed, restore it immediately so the
            // setting takes effect without waiting for the next scroll-up.
            if (disabled) feedService.setFeedScrollingDown(false)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppearanceSettingsScreen(
    onBack: () -> Unit,
    viewModel: AppearanceViewModel = hiltViewModel(),
) {
    val textScale by viewModel.textScale.collectAsState()
    val defaultEmoji by viewModel.defaultEmoji.collectAsState()
    val zapsOnly by viewModel.zapsOnly.collectAsState()
    val disableTabBarAnimation by viewModel.disableTabBarAnimation.collectAsState()
    val compactLines by viewModel.compactLines.collectAsState()
    val threadedLines by viewModel.threadedLines.collectAsState()
    val showTranslateButton by viewModel.showTranslateButton.collectAsState()
    val translateTarget by viewModel.translateTarget.collectAsState()
    val showNewPostsPill by viewModel.showNewPostsPill.collectAsState()
    val sendDelaySeconds by viewModel.sendDelaySeconds.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Appearance") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
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
        ) {
            // Theme colour picker removed — the app ships a single
            // appearance (OLED black with the orange accent).

            // Text size
            SettingHeading("Text Size", SettingsHelp.DISPLAY_TEXT_SIZE)
            Spacer(Modifier.height(8.dp))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("A", color = SecondaryText, fontSize = 12.sp)
                Slider(
                    value = textScale,
                    onValueChange = viewModel::setTextScale,
                    valueRange = 0.8f..1.6f,
                    steps = 7,
                    colors = SliderDefaults.colors(
                        thumbColor = LocalNostrVaultColors.current.primary,
                        activeTrackColor = LocalNostrVaultColors.current.primary,
                    ),
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = 8.dp),
                )
                Text("A", color = SecondaryText, fontSize = 20.sp)
            }

            Text(
                text = "${(textScale * 100).toInt()}%",
                color = TertiaryText,
                fontSize = 13.sp,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )

            Spacer(Modifier.height(32.dp))

            // OLED toggle removed — OLED black is the only appearance now.

            // Feed text: lines per post in the condensed layouts
            SettingHeading("Feed Text")
            Spacer(Modifier.height(8.dp))
            LineCountRow("Compact View", compactLines, SettingsHelp.DISPLAY_COMPACT_LINES, viewModel::setCompactLines)
            LineCountRow("Threaded View", threadedLines, SettingsHelp.DISPLAY_THREADED_LINES, viewModel::setThreadedLines)

            Spacer(Modifier.height(32.dp))

            // Translation: the on-device "Translate" button under posts.
            TranslationSection(
                enabled = showTranslateButton,
                onEnabledChange = viewModel::setShowTranslateButton,
                target = translateTarget,
                targets = viewModel.translateTargets,
                onTargetChange = viewModel::setTranslateTarget,
            )

            Spacer(Modifier.height(32.dp))

            // New Posts pill (iOS Appearance > Feed > "New Posts Pill").
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                SettingHeading("New Posts Pill", SettingsHelp.DISPLAY_NEW_POSTS_PILL, Modifier.weight(1f))
                Switch(
                    checked = showNewPostsPill,
                    onCheckedChange = viewModel::setShowNewPostsPill,
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = PrimaryText,
                        checkedTrackColor = LocalNostrVaultColors.current.primary,
                    ),
                )
            }

            Spacer(Modifier.height(32.dp))

            // Send delay: the undo window before a post goes out
            SettingHeading("Send Delay", SettingsHelp.POST_SEND_DELAY)
            Spacer(Modifier.height(12.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                PendingPostManager.SEND_DELAY_CHOICES.forEach { seconds ->
                    val isSelected = sendDelaySeconds == seconds
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .weight(1f)
                            .height(40.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(
                                if (isSelected) LocalNostrVaultColors.current.primary.copy(alpha = 0.2f)
                                else TertiaryGroupedBg,
                            )
                            .then(
                                if (isSelected) Modifier.border(
                                    2.dp,
                                    LocalNostrVaultColors.current.primary,
                                    RoundedCornerShape(10.dp),
                                )
                                else Modifier
                            )
                            .clickable { viewModel.setSendDelaySeconds(seconds) },
                    ) {
                        Text(
                            text = if (seconds == 0) "Off" else "${seconds}s",
                            color = PrimaryText,
                            fontSize = 15.sp,
                            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                        )
                    }
                }
            }

            Spacer(Modifier.height(32.dp))

            // Keep the tab bar full size (iOS wording)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                SettingHeading("Keep Tab Bar Full Size", SettingsHelp.DISPLAY_TAB_BAR_ANIMATION, Modifier.weight(1f))
                Switch(
                    checked = disableTabBarAnimation,
                    onCheckedChange = viewModel::toggleTabBarAnimation,
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = PrimaryText,
                        checkedTrackColor = LocalNostrVaultColors.current.primary,
                    ),
                )
            }

            Spacer(Modifier.height(32.dp))

            // Zaps Only mode
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                SettingHeading("Zaps Only", SettingsHelp.DISPLAY_ZAPS_ONLY, Modifier.weight(1f))
                Switch(
                    checked = zapsOnly,
                    onCheckedChange = viewModel::toggleZapsOnly,
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = PrimaryText,
                        checkedTrackColor = LocalNostrVaultColors.current.primary,
                    ),
                )
            }

            if (!zapsOnly) {
                Spacer(Modifier.height(32.dp))

                // Default reaction emoji
                SettingHeading("Default Reaction", SettingsHelp.DISPLAY_DEFAULT_REACTION)
                Spacer(Modifier.height(12.dp))

                val emojiOptions = listOf(
                "+" to "+",
                "\u2764\uFE0F" to "\u2764\uFE0F",
                "\uD83D\uDC4D" to "\uD83D\uDC4D",
                "\uD83D\uDD25" to "\uD83D\uDD25",
                "\u26A1" to "\u26A1",
                "\uD83D\uDE02" to "\uD83D\uDE02",
                "\uD83E\uDD14" to "\uD83E\uDD14",
                "\uD83D\uDE4F" to "\uD83D\uDE4F",
            )

            Row(
                horizontalArrangement = Arrangement.SpaceEvenly,
                modifier = Modifier.fillMaxWidth(),
            ) {
                emojiOptions.forEach { (display, value) ->
                    val isSelected = defaultEmoji == value
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(44.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(
                                if (isSelected) LocalNostrVaultColors.current.primary.copy(alpha = 0.2f)
                                else TertiaryGroupedBg,
                            )
                            .then(
                                if (isSelected) Modifier.border(
                                    2.dp,
                                    LocalNostrVaultColors.current.primary,
                                    RoundedCornerShape(10.dp),
                                )
                                else Modifier
                            )
                            .clickable { viewModel.setDefaultEmoji(value) },
                    ) {
                        Text(
                            text = display,
                            fontSize = 20.sp,
                        )
                    }
                }
            }
            }
        }
    }
}

/** One feed layout's line count with minus/plus buttons, clamped to [FeedLineLimits.RANGE]. */
@Composable
private fun LineCountRow(title: String, lines: Int, help: SettingsHelp, onChange: (Int) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
            Text(title, color = PrimaryText, fontSize = 15.sp)
            InfoButton(help)
        }
        LineCountButton("−", "Fewer lines", enabled = lines > FeedLineLimits.RANGE.first) { onChange(lines - 1) }
        Text(
            text = if (lines == 1) "1 line" else "$lines lines",
            color = SecondaryText,
            fontSize = 15.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = Modifier.width(72.dp),
        )
        LineCountButton("+", "More lines", enabled = lines < FeedLineLimits.RANGE.last) { onChange(lines + 1) }
    }
}

@Composable
private fun LineCountButton(symbol: String, label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(SecondaryText.copy(alpha = if (enabled) 0.15f else 0.06f))
            .clickable(enabled = enabled, onClickLabel = label, onClick = onClick),
    ) {
        Text(symbol, color = if (enabled) PrimaryText else TertiaryText, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
    }
}

/**
 * Appearance > Translation: the "Translate" button under posts in another
 * language, and the language they translate into. Translation runs on the
 * phone (ML Kit); only the language model is downloaded, once per language.
 */
@Composable
private fun TranslationSection(
    enabled: Boolean,
    onEnabledChange: (Boolean) -> Unit,
    target: String,
    targets: List<String>,
    onTargetChange: (String) -> Unit,
) {
    Text(
        text = "Translation",
        color = PrimaryText,
        fontSize = 16.sp,
        fontWeight = FontWeight.SemiBold,
    )
    Spacer(Modifier.height(8.dp))
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(text = "Translate Button on Posts", color = PrimaryText, fontSize = 15.sp)
            Text(
                text = "Posts in another language get a Translate button. Translation happens on your phone; " +
                    "the first time for a language, its model is downloaded from Google.",
                color = SecondaryText,
                fontSize = 13.sp,
            )
        }
        Switch(
            checked = enabled,
            onCheckedChange = onEnabledChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = PrimaryText,
                checkedTrackColor = LocalNostrVaultColors.current.primary,
            ),
        )
    }

    if (enabled) {
        var expanded by remember { mutableStateOf(false) }
        Box {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClickLabel = "Choose language") { expanded = true }
                    .padding(vertical = 12.dp),
            ) {
                Text("Translate To", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
                Text(
                    text = FeedLanguage(target).displayName(),
                    color = LocalNostrVaultColors.current.primary,
                    fontSize = 15.sp,
                )
            }
            DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
                modifier = Modifier.heightIn(max = 420.dp),
            ) {
                targets.forEach { code ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = FeedLanguage(code).displayName(),
                                color = if (code == target) LocalNostrVaultColors.current.primary else PrimaryText,
                                fontWeight = if (code == target) FontWeight.SemiBold else FontWeight.Normal,
                            )
                        },
                        onClick = {
                            onTargetChange(code)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}

/** A setting's title with its (i), in place of a grey caption under it. */
@Composable
private fun SettingHeading(title: String, help: SettingsHelp? = null, modifier: Modifier = Modifier) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        Text(
            text = title,
            color = PrimaryText,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
        )
        if (help != null) InfoButton(help)
    }
}
