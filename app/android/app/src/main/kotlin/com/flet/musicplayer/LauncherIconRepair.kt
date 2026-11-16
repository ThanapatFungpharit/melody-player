package com.flet.musicplayer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Runs [LauncherIcon.repair] after Melody is updated, before it next starts. */
class LauncherIconRepair : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        try {
            LauncherIcon.repair(context)
        } catch (error: RuntimeException) {
            // A crash here would only add a "Melody keeps stopping" dialog.
            Log.w("Melody", "Could not repair the launcher icon", error)
        }
    }
}
