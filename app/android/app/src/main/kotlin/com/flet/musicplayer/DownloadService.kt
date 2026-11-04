package com.flet.musicplayer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder

/**
 * Keeps Melody's process alive while downloads run and it is off screen.
 *
 * The downloads run in Melody's own worker; this service only holds the
 * notification that entitles the process to keep running. Android refuses to
 * start it for an app already in the background, and limits how long it may
 * run. Either way the downloads carry on for as long as Android allows, and
 * the next launch starts over any that it stopped.
 */
class DownloadService : Service() {
    companion object {
        private const val CHANNEL_ID = "melody_downloads"
        private const val NOTIFICATION_ID = 4102

        // How many downloads Melody last reported. A service that is starting
        // can't be stopped from outside: Android treats that as never having
        // called startForeground and ends the app. It reads this once started.
        private var active = 0
        private var running: DownloadService? = null

        /** Returns whether the service is running or starting as needed. */
        fun update(context: Context, count: Int): Boolean {
            active = count
            running?.let {
                it.refresh()
                return true
            }
            if (count <= 0) return true
            return try {
                context.startForegroundService(Intent(context, DownloadService::class.java))
                true
            } catch (error: IllegalStateException) {
                false
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW),
        )
        running = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        refresh()
        return START_NOT_STICKY
    }

    // Android 15 limits this kind of service to six hours a day.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        running = null
        super.onDestroy()
    }

    private fun refresh() {
        try {
            startForeground(
                NOTIFICATION_ID,
                notification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } catch (error: IllegalStateException) {
            stopSelf()
            return
        }
        if (active <= 0) stopSelf()
    }

    private fun notification(): Notification {
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Downloading music")
            .setContentText(if (active == 1) "1 song" else "$active songs")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }
}
