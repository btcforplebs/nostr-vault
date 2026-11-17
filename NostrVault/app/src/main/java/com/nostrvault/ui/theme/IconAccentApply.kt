package com.nostrvault.ui.theme

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log

/**
 * Switches the launcher alias to the one [IconAccent] picks (twin of
 * IconAccentApply.swift). The setting lives on this phone only, like the
 * iOS @AppStorage. Changes nothing when the right alias is already the only
 * one on, so calling it at every start and every accent change is cheap.
 * The launcher may take a few seconds to redraw the icon.
 */
object IconAccentApply {
    private const val PREFS = "nv_icon_accent"
    const val FOLLOWS_KEY = "iconFollowsAccent"

    fun follows(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(FOLLOWS_KEY, false)

    fun setFollows(context: Context, on: Boolean, accentSetting: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(FOLLOWS_KEY, on).apply()
        apply(context, accentSetting)
    }

    fun apply(context: Context, accentSetting: String) {
        val pm = context.packageManager
        val pkg = context.packageName
        val want = IconAccent.aliasFor(accentSetting, follows(context))
        fun component(alias: String) = ComponentName(pkg, "com.nostrvault.$alias")
        fun isOn(alias: String): Boolean = when (pm.getComponentEnabledSetting(component(alias))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> alias == IconAccent.DEFAULT_ALIAS
            else -> false
        }
        try {
            // The wanted one first, so there is never a moment with no launcher entry.
            if (!isOn(want)) set(pm, component(want), true)
            for ((_, alias) in IconAccent.aliases) {
                if (alias != want && isOn(alias)) set(pm, component(alias), false)
            }
        } catch (e: Exception) {
            Log.w("IconAccent", "could not switch the launcher icon", e)
        }
    }

    private fun set(pm: PackageManager, c: ComponentName, on: Boolean) {
        pm.setComponentEnabledSetting(
            c,
            if (on) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
    }
}
