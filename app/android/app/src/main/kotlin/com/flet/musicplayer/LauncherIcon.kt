package com.flet.musicplayer

import android.app.Activity
import android.content.ComponentName
import android.content.pm.PackageManager
import android.os.Build

/**
 * Shows the launcher entry whose icon matches the saved accent color.
 *
 * Every accent has an `icon.<accent>` activity-alias of [MainActivity] in the
 * manifest, with only the default enabled. Exactly one alias may be enabled at
 * a time: two enabled aliases are two Melody icons in the launcher.
 *
 * The requested alias is enabled first so Melody never drops out of the
 * launcher; a switch cut short (the process killed after a recents swipe,
 * while [MainActivity] is being destroyed) is repaired the next time Melody
 * leaves the screen. PackageManager ignores aliases already in the asked-for
 * state, so an unchanged accent writes and broadcasts nothing.
 *
 * The splash screen Android 12+ draws takes its icon from the component that
 * started the task: the old alias after a switch, or the default icon when
 * the notification opens [MainActivity]. Android 13+ instead gets the
 * accent's `LaunchTheme.<accent>` (res/values-v31/splash_themes.xml) for
 * later launches; Android 12 keeps the system's choice.
 */
object LauncherIcon {
    private val prefix = "${MainActivity::class.java.`package`!!.name}.icon."

    fun apply(activity: Activity, accent: String) {
        applySplashTheme(activity, accent)
        val packageManager = activity.packageManager
        @Suppress("DEPRECATION")
        val aliases = packageManager
            .getPackageInfo(
                activity.packageName,
                PackageManager.GET_ACTIVITIES or PackageManager.MATCH_DISABLED_COMPONENTS,
            )
            .activities
            .orEmpty()
            .map { it.name }
            .filter { it.startsWith(prefix) }
        val wanted = prefix + accent
        if (wanted !in aliases) return
        for (alias in aliases.sortedBy { it != wanted }) {
            packageManager.setComponentEnabledSetting(
                ComponentName(activity.packageName, alias),
                if (alias == wanted) {
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                } else {
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                },
                PackageManager.DONT_KILL_APP,
            )
        }
    }

    private fun applySplashTheme(activity: Activity, accent: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        // The resource table keeps the XML name's dots; `LaunchTheme_<accent>`
        // is only the R field name and is never found.
        @Suppress("DiscouragedApi")
        val theme = activity.resources
            .getIdentifier("LaunchTheme.$accent", "style", activity.packageName)
        if (theme != 0) activity.splashScreen.setSplashScreenTheme(theme)
    }
}
