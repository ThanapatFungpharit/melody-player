package com.flet.musicplayer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Runs [LauncherIcon.repair] after Melody is updated, before it next starts. */
class LauncherIconRepair : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            LauncherIcon.repair(context)
        }
    }
}
