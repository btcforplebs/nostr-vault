package com.nostrvault.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.FilterAlt
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.FilterAlt
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.SearchFilter
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

private val SearchFilter.Who.icon: ImageVector
    get() = when (this) {
        SearchFilter.Who.EVERYONE -> Icons.Filled.Public
        SearchFilter.Who.FOLLOWS -> Icons.Filled.People
        SearchFilter.Who.YOU -> Icons.Filled.AccountCircle
    }

private val SearchFilter.Period.icon: ImageVector
    get() = when (this) {
        SearchFilter.Period.ANY_TIME -> Icons.Filled.Schedule
        SearchFilter.Period.DAY -> Icons.Filled.History
        SearchFilter.Period.WEEK -> Icons.Filled.DateRange
        SearchFilter.Period.MONTH -> Icons.Filled.CalendarMonth
    }

/**
 * The Search tab's top-right control (iOS `SearchFilterMenu`): one menu with the
 * "who" and "when" filters, and Clear once anything is on. A bare funnel when
 * nothing is filtered, a filled one in the accent when something is; the caption
 * under the field says what. Stays open so who and when can be set in one visit.
 */
@Composable
internal fun SearchFilterMenu(filter: SearchFilter, onChange: (SearchFilter) -> Unit, accent: Color) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(
            onClick = { open = true },
            modifier = Modifier.size(40.dp).semantics {
                contentDescription = "Filter"
                stateDescription = filter.accessibilitySummary
            },
        ) {
            Icon(
                if (filter.isActive) Icons.Filled.FilterAlt else Icons.Outlined.FilterAlt,
                contentDescription = null,
                tint = if (filter.isActive) accent else SecondaryText,
                modifier = Modifier.size(25.dp),
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            MenuHeader("Who")
            SearchFilter.Who.entries.forEach { who ->
                DropdownMenuItem(
                    text = { Text(who.label) },
                    leadingIcon = { Icon(if (filter.who == who) Icons.Filled.Check else who.icon, null, Modifier.size(18.dp)) },
                    onClick = { onChange(filter.copy(who = who)) },
                )
            }
            HorizontalDivider()
            MenuHeader("When")
            SearchFilter.Period.entries.forEach { period ->
                DropdownMenuItem(
                    text = { Text(period.label) },
                    leadingIcon = { Icon(if (filter.period == period) Icons.Filled.Check else period.icon, null, Modifier.size(18.dp)) },
                    onClick = { onChange(filter.copy(period = period)) },
                )
            }
            if (filter.isActive) {
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("Clear filter", color = ErrorRed) },
                    leadingIcon = { Icon(Icons.Outlined.Cancel, null, Modifier.size(18.dp), tint = ErrorRed) },
                    onClick = {
                        onChange(SearchFilter.ALL)
                        open = false
                    },
                )
            }
        }
    }
}

@Composable
private fun MenuHeader(text: String) {
    Text(text, color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
}

/**
 * The line under the search field while a filter is on (iOS
 * `SearchFilterCaption`): "People you follow · Last week", with Clear at the
 * end. Nothing when no filter is on.
 */
@Composable
internal fun SearchFilterCaption(filter: SearchFilter, onClear: () -> Unit, accent: Color) {
    val caption = filter.caption ?: return
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
        Icon(Icons.Filled.FilterAlt, contentDescription = null, tint = accent, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(6.dp))
        Text(
            caption,
            color = PrimaryText.copy(alpha = 0.85f),
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).semantics { contentDescription = filter.accessibilitySummary },
        )
        // 12 sp text is a small target: the hit area is 48 dp.
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.defaultMinSize(minWidth = 48.dp, minHeight = 48.dp).clickable(onClick = onClear),
        ) {
            Text("Clear filter", color = accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}
