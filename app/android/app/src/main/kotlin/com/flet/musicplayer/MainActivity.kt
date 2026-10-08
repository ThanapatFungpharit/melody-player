package com.flet.musicplayer

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps the decoder's Dart engine alive after Android removes the task.
 *
 * The media-session foreground service survives a recents swipe, but the
 * default FlutterActivity destroys its engine, leaving a live notification
 * with no decoder. Cache the first-launch engine and attach the next activity
 * to it when Melody or its notification is opened again.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val ENGINE_ID = "melody-player"
        private const val ICON_CHANNEL = "melody/app_icon"

        // The accent whose launcher icon waits for Melody to leave the screen.
        // It lives with the process, like the cached engine that sends it, so
        // an accent sent while no activity is attached is still applied.
        private var pendingIcon: String? = null

        // Holds no activity: the cached engine outlives every MainActivity and
        // would otherwise keep a destroyed one alive.
        private val iconHandler = MethodChannel.MethodCallHandler { call, result ->
            when (call.method) {
                "setAccent" -> {
                    pendingIcon = call.arguments as? String
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // Set while an activity Melody started, such as a file picker, opens in
    // this task. Android reports that as the user leaving too, but switching
    // the icon then can close the task, picker included.
    private var startingOwnActivity = false

    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(ENGINE_ID)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        flutterEngine?.let { engine ->
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ICON_CHANNEL)
            .setMethodCallHandler(iconHandler)
    }

    // startActivity and its overloads all end here.
    override fun startActivityForResult(intent: Intent, requestCode: Int, options: Bundle?) {
        startingOwnActivity = true
        try {
            super.startActivityForResult(intent, requestCode, options)
        } catch (error: RuntimeException) {
            // Nothing opened, so no resume will follow to clear the flag.
            startingOwnActivity = false
            throw error
        }
    }

    override fun onResume() {
        super.onResume()
        startingOwnActivity = false
    }

    // Launchers can close a task whose entry is switched under it, so the
    // icon changes only once the user takes Melody off the screen.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!startingOwnActivity) applyPendingIcon()
    }

    override fun onDestroy() {
        // A configuration change configChanges doesn't cover (bold text,
        // for one) recreates the activity while Melody is still on screen.
        if (!isChangingConfigurations) applyPendingIcon()
        super.onDestroy()
    }

    private fun applyPendingIcon() {
        val accent = pendingIcon ?: return
        pendingIcon = null
        LauncherIcon.apply(this, accent)
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
