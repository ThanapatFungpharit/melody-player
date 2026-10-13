package com.melodyplayer.melody_audio

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.os.Environment
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MelodyAudioPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(
            binding.binaryMessenger,
            "com.melodyplayer.melody_audio/native",
        )
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "nativeLibraryDir" -> result.success(context.applicationInfo.nativeLibraryDir)
            "openMusicFolder" -> {
                val folder = call.argument<String>("relativePath")?.trim()?.trim('/').orEmpty()
                result.success(openMusicFolder(folder))
            }
            "publicMusicDir" -> result.success(
                Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_MUSIC,
                ).absolutePath,
            )
            else -> result.notImplemented()
        }
    }

    /**
     * Shows Music/[folder] in the system Files app. Files opens a folder
     * from its document URI; when no app handles that, the storage root is
     * shown instead. Returns false when neither can be opened.
     */
    private fun openMusicFolder(folder: String): Boolean {
        val authority = "com.android.externalstorage.documents"
        val path = listOf(Environment.DIRECTORY_MUSIC, folder)
            .filter { it.isNotEmpty() }
            .joinToString("/")
        val attempts = listOf(
            DocumentsContract.buildDocumentUri(authority, "primary:$path") to
                DocumentsContract.Document.MIME_TYPE_DIR,
            DocumentsContract.buildRootUri(authority, "primary") to
                "vnd.android.document/root",
        )
        for ((uri, type) in attempts) {
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, type)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            try {
                context.startActivity(intent)
                return true
            } catch (missing: ActivityNotFoundException) {
                continue
            } catch (denied: SecurityException) {
                continue
            }
        }
        return false
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
