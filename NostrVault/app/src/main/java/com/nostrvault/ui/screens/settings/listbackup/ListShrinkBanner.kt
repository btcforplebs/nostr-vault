package com.nostrvault.ui.screens.settings.listbackup

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.service.ListShrinkRule
import com.nostrvault.service.ListVersion
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

private val Orange = Color(0xFFFF9500)

/**
 * On the vault dashboard: a list that just lost most of what it held, from the
 * vault's history. "Your bookmarks went from 240 to 0 on 2 Nov." Restore asks
 * first (ListRestoreDialog); "Keep the new list" hides it for good. Nothing is
 * ever restored on its own. Twin of iOS `ListWipeBanner`.
 */
@Composable
fun ListShrinkBanner(viewModel: ListBackupViewModel = hiltViewModel()) {
    val wipes by viewModel.wipes.collectAsState()
    val account by viewModel.account.collectAsState()
    var restoring by remember { mutableStateOf<ListVersion?>(null) }
    LaunchedEffect(account) { viewModel.load() }

    if (wipes.isNotEmpty()) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            wipes.take(3).forEach { (key, wipe) ->
                val from = ListShrinkRule.itemCount(wipe.before)
                val to = ListShrinkRule.itemCount(wipe.after)
                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = Orange.copy(alpha = 0.1f),
                    border = BorderStroke(1.dp, Orange.copy(alpha = 0.4f)),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(Modifier.padding(14.dp)) {
                        Row(verticalAlignment = Alignment.Top) {
                            Icon(Icons.Filled.Warning, contentDescription = null, tint = Orange, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(12.dp))
                            Column {
                                Text(
                                    "Your ${ListBackupFormat.title(key).lowercase()} went from $from to $to on ${ListBackupFormat.day(wipe.after.createdAt)}.",
                                    color = PrimaryText,
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 15.sp,
                                )
                                Text("Your vault kept the list from before. Restore it?", color = SecondaryText, fontSize = 14.sp)
                            }
                        }
                        Spacer(Modifier.size(10.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Button(onClick = { restoring = wipe.before }) { Text("Restore") }
                            OutlinedButton(onClick = { viewModel.dismiss(wipe) }) { Text("Keep the new list") }
                        }
                    }
                }
            }
        }
    }
    restoring?.let { old -> ListRestoreDialog(old = old, viewModel = viewModel, onClose = { restoring = null }) }
}
