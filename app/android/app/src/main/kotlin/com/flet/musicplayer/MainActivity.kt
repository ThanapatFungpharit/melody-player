package com.flet.musicplayer

import android.content.Context
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
        private const val DOWNLOADS_CHANNEL = "melody/downloads"
    }

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
        // The application context: the cached engine outlives every MainActivity
        // and would otherwise keep a destroyed one alive.
        val appContext = applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOADS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setActive" -> result.success(
                        DownloadService.update(appContext, call.arguments as? Int ?: 0),
                    )
                    else -> result.notImplemented()
                }
            }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
