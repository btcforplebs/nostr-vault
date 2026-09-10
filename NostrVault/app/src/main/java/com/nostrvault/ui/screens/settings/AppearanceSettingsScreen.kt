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
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Appearance settings: theme color, text size, OLED mode.
 */

@HiltViewModel
class AppearanceViewModel @Inject constructor(
    private val configStore: ConfigStore,
) : ViewModel() {

    private val _selectedTheme = MutableStateFlow(AppTheme.DEFAULT)
    val selectedTheme = _selectedTheme.asStateFlow()

    private val _textScale = MutableStateFlow(2.0f)
    val textScale = _textScale.asStateFlow()

    private val _oledMode = MutableStateFlow(false)
    val oledMode = _oledMode.asStateFlow()

    private val _defaultEmoji = MutableStateFlow("+")
    val defaultEmoji = _defaultEmoji.asStateFlow()

    init {
        val config = configStore.config.value
        _selectedTheme.value = AppTheme.fromKey(config.themeColor)
        _textScale.value = config.textSizeScale
        _oledMode.value = config.oledMode
        _defaultEmoji.value = config.defaultReactionEmoji
    }

    fun selectTheme(theme: AppTheme) {
        _selectedTheme.value = theme
        viewModelScope.launch {
            configStore.update { it.copy(themeColor = theme.key) }
        }
    }

    fun setTextScale(scale: Float) {
        _textScale.value = scale
        viewModelScope.launch {
            configStore.update { it.copy(textSizeScale = scale) }
        }
    }

    fun toggleOled(enabled: Boolean) {
        _oledMode.value = enabled
        viewModelScope.launch {
            configStore.update { it.copy(oledMode = enabled) }
        }
    }

    fun setDefaultEmoji(emoji: String) {
        _defaultEmoji.value = emoji
        viewModelScope.launch {
            configStore.update { it.copy(defaultReactionEmoji = emoji) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppearanceSettingsScreen(
    onBack: () -> Unit,
    viewModel: AppearanceViewModel = hiltViewModel(),
) {
    val selectedTheme by viewModel.selectedTheme.collectAsState()
    val textScale by viewModel.textScale.collectAsState()
    val oledMode by viewModel.oledMode.collectAsState()
    val defaultEmoji by viewModel.defaultEmoji.collectAsState()

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
            // Theme color picker
            Text(
                text = "Theme Color",
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(12.dp))

            Row(
                horizontalArrangement = Arrangement.SpaceEvenly,
                modifier = Modifier.fillMaxWidth(),
            ) {
                AppTheme.entries.forEach { theme ->
                    ThemeColorDot(
                        theme = theme,
                        isSelected = theme == selectedTheme,
                        onClick = { viewModel.selectTheme(theme) },
                    )
                }
            }

            Spacer(Modifier.height(32.dp))

            // Text size
            Text(
                text = "Text Size",
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(8.dp))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("A", color = SecondaryText, fontSize = 12.sp)
                Slider(
                    value = textScale,
                    onValueChange = viewModel::setTextScale,
                    valueRange = 0.8f..2.4f,
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

            // OLED mode
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "OLED Black Mode",
                        color = PrimaryText,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "Deeper blacks for AMOLED displays",
                        color = SecondaryText,
                        fontSize = 13.sp,
                    )
                }
                Switch(
                    checked = oledMode,
                    onCheckedChange = viewModel::toggleOled,
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = PrimaryText,
                        checkedTrackColor = LocalNostrVaultColors.current.primary,
                    ),
                )
            }

            Spacer(Modifier.height(32.dp))

            // Default reaction emoji
            Text(
                text = "Default Reaction",
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Used for quick-react on notes",
                color = SecondaryText,
                fontSize = 13.sp,
            )
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

@Composable
private fun ThemeColorDot(
    theme: AppTheme,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.clickable(onClick = onClick),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(theme.colors.primary)
                .then(
                    if (isSelected) Modifier.border(3.dp, PrimaryText, CircleShape)
                    else Modifier
                ),
        ) {
            if (isSelected) {
                Icon(
                    imageVector = NostrVaultIcons.Check,
                    contentDescription = null,
                    tint = PrimaryText,
                    modifier = Modifier
                        .size(18.dp)
                        .align(Alignment.Center),
                )
            }
        }
        Spacer(Modifier.height(4.dp))
        Text(
            text = theme.displayName.split(" ").first(),
            color = if (isSelected) PrimaryText else TertiaryText,
            fontSize = 10.sp,
        )
    }
}
