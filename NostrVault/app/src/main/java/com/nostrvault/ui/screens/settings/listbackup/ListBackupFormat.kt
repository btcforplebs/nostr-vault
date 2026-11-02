package com.nostrvault.ui.screens.settings.listbackup

import com.nostrvault.service.ListHistory
import com.nostrvault.service.ListShrinkRule
import com.nostrvault.service.ListVersion
import java.text.DateFormat
import java.util.Date

/** How list versions read on screen. Twin of iOS `ListBackupFormat`. */
internal object ListBackupFormat {
    fun date(createdAt: Long): String =
        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(createdAt * 1000))

    fun day(createdAt: Long): String =
        java.text.SimpleDateFormat("d MMM", java.util.Locale.getDefault()).format(Date(createdAt * 1000))

    fun count(v: ListVersion): String {
        val n = ListShrinkRule.itemCount(v)
        if (v.kind == 0) return if (n == 1) "1 field" else "$n fields"
        val base = if (n == 1) "1 item" else "$n items"
        return if (v.kind in ListShrinkRule.encryptedKinds && v.content.isNotEmpty()) "$base + private items" else base
    }

    fun title(key: ListHistory.Key): String {
        val name = ListShrinkRule.name(key.kind).replaceFirstChar { it.uppercase() }
        return if (key.d.isEmpty()) name else "$name “${key.d}”"
    }
}
