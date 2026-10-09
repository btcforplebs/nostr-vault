package com.nostrvault.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * Custom zap amount selection bottom sheet.
 * Matches iOS CustomZapSheet with preset amounts and custom input.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CustomZapSheet(
    sheetState: SheetState,
    /** Starts selected: the default zap amount from Wallet settings, in sats. */
    defaultAmount: Int,
    onDismiss: () -> Unit,
    onZap: (Int) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var selectedAmount by remember { mutableIntStateOf(defaultAmount.coerceAtLeast(1)) }
    var customAmount by remember { mutableStateOf("") }
    var useCustom by remember { mutableStateOf(false) }

    val presetAmounts = listOf(21, 100, 500, 1_000, 5_000, 10_000, 50_000)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = SecondaryGroupedBg,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
        ) {
            // Title
            Text(
                text = "Zap Amount",
                color = PrimaryText,
                fontWeight = FontWeight.Bold,
                fontSize = 20.sp,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )

            Spacer(Modifier.height(4.dp))

            Text(
                text = "Choose how many sats to zap",
                color = SecondaryText,
                fontSize = 14.sp,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )

            Spacer(Modifier.height(20.dp))

            // Preset grid, 4 across as on iOS
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                for (row in presetAmounts.chunked(PRESET_COLUMNS)) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        for (amount in row) {
                            val isSelected = !useCustom && selectedAmount == amount
                            OutlinedButton(
                                onClick = {
                                    selectedAmount = amount
                                    useCustom = false
                                    customAmount = ""
                                },
                                shape = RoundedCornerShape(10.dp),
                                // Four across: the default 24dp side padding would wrap "10K".
                                contentPadding = PaddingValues(horizontal = 4.dp),
                                colors = ButtonDefaults.outlinedButtonColors(
                                    containerColor = if (isSelected) colors.primary.copy(alpha = 0.15f)
                                    else WindowBackground.copy(alpha = 0.5f),
                                ),
                                border = ButtonDefaults.outlinedButtonBorder(enabled = true).copy(
                                    brush = Brush.linearGradient(
                                        listOf(
                                            if (isSelected) colors.primary else SeparatorColor,
                                            if (isSelected) colors.primary else SeparatorColor,
                                        )
                                    )
                                ),
                                modifier = Modifier
                                    .weight(1f)
                                    .height(48.dp),
                            ) {
                                Text(
                                    text = formatZapAmount(amount),
                                    color = if (isSelected) colors.primary else PrimaryText,
                                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                                    fontSize = 16.sp,
                                    maxLines = 1,
                                )
                            }
                        }
                        // A short last row keeps the grid's column widths.
                        repeat(PRESET_COLUMNS - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // Custom amount input
            OutlinedTextField(
                value = customAmount,
                onValueChange = { value ->
                    customAmount = value.filter { it.isDigit() }
                    val parsed = customAmount.toIntOrNull()
                    if (parsed != null && parsed > 0) {
                        selectedAmount = parsed
                        useCustom = true
                    }
                },
                placeholder = { Text("Custom amount", color = PlaceholderText) },
                suffix = { Text("sats", color = SecondaryText, fontSize = 14.sp) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                singleLine = true,
                shape = RoundedCornerShape(10.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.primary,
                    unfocusedBorderColor = SeparatorColor,
                    cursorColor = colors.primary,
                    focusedTextColor = PrimaryText,
                    unfocusedTextColor = PrimaryText,
                ),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(20.dp))

            // Zap button
            val effectiveAmount = if (useCustom) customAmount.toIntOrNull() ?: 0 else selectedAmount
            Button(
                onClick = {
                    if (effectiveAmount > 0) {
                        ZapFlight.sheetConfirmed()
                        onZap(effectiveAmount)
                        onDismiss()
                    }
                },
                enabled = effectiveAmount > 0,
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = ZapOrange,
                    contentColor = PrimaryText,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Zap,
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "Zap ${if (effectiveAmount > 0) "%,d".format(effectiveAmount) else "---"} sats",
                    fontWeight = FontWeight.Bold,
                    fontSize = 16.sp,
                )
            }
        }
    }
}

private const val PRESET_COLUMNS = 4

/** Preset labels only: every preset is a round number of thousands. */
private fun formatZapAmount(amount: Int): String {
    return when {
        amount >= 1000 -> "${amount / 1000}K"
        else -> amount.toString()
    }
}
