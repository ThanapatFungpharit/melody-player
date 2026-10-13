package com.flet.musicplayer

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.pm.PackageManager.ComponentEnabledSetting
import android.os.Build

/**
 * Shows the launcher entry whose icon matches the saved accent color.
 *
 * Every accent has an `icon.<accent>` activity-alias of [MainActivity] in the
 * manifest, with only the default enabled. Exactly one alias may be enabled at
 * a time: two enabled aliases are two Melody icons in the launcher.
 *
 * Android 13+ switches every alias in one atomic call. Older versions enable
 * the requested alias first so Melody never drops out of the launcher; a
 * switch cut short there (the process killed after a recents swipe, while
 * [MainActivity] is being destroyed) leaves two icons until Melody next starts
 * and leaves the screen. PackageManager ignores aliases already in the asked-for
 * state, so an unchanged accent writes and broadcasts nothing.
 *
 * The splash screen Android 12+ draws takes its icon from the component that
 * started the task: the old alias after a switch, or the default icon when
 * the notification opens [MainActivity]. Android 13+ instead gets the
 * accent's `LaunchTheme.<accent>` (res/values-v31/splash_themes.xml) for
 * later launches; Android 12 keeps the system's choice.
 *
 * Android keeps each alias's enabled state across updates and forgets the
 * state of an alias an update drops. An update that removed or renamed the
 * enabled alias would leave Melody with no launcher entry, so shipped aliases
 * stay in the manifest (test/ui/app_icon_test.dart holds the list) and
 * [repair] runs after every update as a backstop.
 */
object LauncherIcon {
    private val prefix = "${MainActivity::class.java.`package`!!.name}.icon."

    fun apply(activity: Activity, accent: String) {
        applySplashTheme(activity, accent)
        val packageManager = activity.packageManager
        val aliases = aliases(activity).map { it.name }
        val wanted = prefix + accent
        if (wanted !in aliases) return
        val states = aliases.sortedBy { it != wanted }.map { alias ->
            ComponentName(activity.packageName, alias) to if (alias == wanted) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // One call, applied as a whole: a process killed mid-switch can't
            // leave both the old and the new alias enabled.
            packageManager.setComponentEnabledSettings(
                states.map { (component, state) ->
                    ComponentEnabledSetting(component, state, PackageManager.DONT_KILL_APP)
                },
            )
        } else {
            for ((component, state) in states) {
                packageManager.setComponentEnabledSetting(
                    component,
                    state,
                    PackageManager.DONT_KILL_APP,
                )
            }
        }
    }

    /**
     * Restores the manifest's default launcher entry when no alias is enabled.
     *
     * Melody sends the saved accent again on its next start, so the icon shows
     * the default color only until Melody first leaves the screen.
     */
    fun repair(context: Context) {
        val packageManager = context.packageManager
        val aliases = aliases(context)
        val anyEnabled = aliases.any { alias ->
            val component = ComponentName(context.packageName, alias.name)
            when (packageManager.getComponentEnabledSetting(component)) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> alias.enabled
                else -> false
            }
        }
        if (anyEnabled) return
        for (alias in aliases) {
            packageManager.setComponentEnabledSetting(
                ComponentName(context.packageName, alias.name),
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT,
                PackageManager.DONT_KILL_APP,
            )
        }
    }

    // ActivityInfo.enabled is the manifest's value, whatever the saved state.
    private fun aliases(context: Context): List<ActivityInfo> {
        @Suppress("DEPRECATION")
        return context.packageManager
            .getPackageInfo(
                context.packageName,
                PackageManager.GET_ACTIVITIES or PackageManager.MATCH_DISABLED_COMPONENTS,
            )
            .activities
            .orEmpty()
            .filter { it.name.startsWith(prefix) }
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
