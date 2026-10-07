package com.melodyplayer.melody_audio

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors

class MelodyAudioPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

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
            "publishAudio" -> {}
            "nativeLibraryDir" -> {
                result.success(context.applicationInfo.nativeLibraryDir)
                return
            }
            "publicMusicDir" -> {
                result.success(
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_MUSIC,
                    ).absolutePath,
                )
                return
            }
            else -> {
                result.notImplemented()
                return
            }
        }
        val source = call.argument<String>("source")
        val relativePath = call.argument<String>("relativePath") ?: "Melody"
        if (source.isNullOrBlank()) {
            result.error("invalid_source", "A staged audio path is required", null)
            return
        }
        executor.execute {
            try {
                val published = publishAudio(File(source), relativePath)
                mainHandler.post { result.success(published) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error(
                        "publish_failed",
                        error.message ?: "Could not publish audio to Music",
                        null,
                    )
                }
            }
        }
    }

    private fun publishAudio(source: File, relativePath: String): Map<String, String> {
        require(source.isFile && source.length() > 0) { "The staged audio file is missing" }
        val extension = source.extension.lowercase()
        val mimeType = when (extension) {
            "webm" -> "audio/webm"
            "mp4", "m4a" -> "audio/mp4"
            "ogg", "oga", "opus" -> "audio/ogg"
            "flac" -> "audio/flac"
            else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?.takeIf { it.startsWith("audio/") } ?: "audio/mpeg"
        }
        val folder = relativePath.trim().trim('/').ifBlank { "Melody" }
        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, source.name)
            put(MediaStore.Audio.Media.MIME_TYPE, mimeType)
            put(MediaStore.Audio.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MUSIC}/$folder")
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val collection = MediaStore.Audio.Media.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY,
        )
        val uri = resolver.insert(collection, values)
            ?: error("Android could not allocate a Music file")
        try {
            resolver.openOutputStream(uri, "w").use { output ->
                requireNotNull(output) { "Android could not open the Music file" }
                FileInputStream(source).use { input -> input.copyTo(output) }
            }
            values.clear()
            values.put(MediaStore.Audio.Media.IS_PENDING, 0)
            check(resolver.update(uri, values, null, null) > 0) {
                "Android could not finish publishing the Music file"
            }
            val publishedName = queryString(uri, MediaStore.Audio.Media.DISPLAY_NAME)
                ?: source.name
            val publishedPath = queryString(uri, MediaStore.Audio.Media.DATA)
                ?: File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
                    "$folder/$publishedName",
                ).absolutePath
            return mapOf(
                "path" to publishedPath,
                "uri" to uri.toString(),
                "name" to publishedName,
            )
        } catch (error: Throwable) {
            // Report the copy failure, not a secondary cleanup failure.
            runCatching { resolver.delete(uri, null, null) }
                .onFailure { error.addSuppressed(it) }
            throw error
        }
    }

    private fun queryString(uri: Uri, column: String): String? {
        context.contentResolver.query(uri, arrayOf(column), null, null, null).use { cursor ->
            if (cursor == null || !cursor.moveToFirst()) return null
            val index = cursor.getColumnIndex(column)
            return if (index >= 0 && !cursor.isNull(index)) cursor.getString(index) else null
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }
}
