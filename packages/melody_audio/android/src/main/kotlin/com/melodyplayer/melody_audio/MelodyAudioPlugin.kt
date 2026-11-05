package com.melodyplayer.melody_audio

import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.Context
import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MelodyAudioPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingDelete: MethodChannel.Result? = null

    /**
     * Asks the user to confirm deleting audio files this app did not create.
     * Android 11+ refuses a plain delete of such files, even with audio
     * access; the system dialog is the only way. Replies true when the user
     * allowed it. Files MediaStore does not know cannot be deleted this way.
     */
    private fun deleteMediaFiles(paths: List<String>, result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(false)
            return
        }
        if (pendingDelete != null) {
            result.error("busy", "A delete request is already open", null)
            return
        }
        val collection = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val uris = ArrayList<Uri>()
        for (path in paths) {
            context.contentResolver.query(
                collection,
                arrayOf(MediaStore.Audio.Media._ID),
                "${MediaStore.Audio.Media.DATA} = ?",
                arrayOf(path),
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    uris.add(ContentUris.withAppendedId(collection, cursor.getLong(0)))
                }
            }
        }
        if (uris.isEmpty()) {
            result.success(false)
            return
        }
        try {
            val request = MediaStore.createDeleteRequest(context.contentResolver, uris)
            pendingDelete = result
            activity.startIntentSenderForResult(
                request.intentSender, DELETE_REQUEST, null, 0, 0, 0,
            )
        } catch (error: Exception) {
            pendingDelete = null
            result.error("delete_failed", error.message, null)
        }
    }

    private val activityResultListener =
        io.flutter.plugin.common.PluginRegistry.ActivityResultListener { code, resultCode, _ ->
            if (code != DELETE_REQUEST) return@ActivityResultListener false
            pendingDelete?.success(resultCode == Activity.RESULT_OK)
            pendingDelete = null
            true
        }

    /** The permission that lets the app see audio files other apps put in Music. */
    private val audioPermission: String
        get() = if (Build.VERSION.SDK_INT >= 33) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    private fun hasAudioAccess() = context.checkSelfPermission(audioPermission) ==
        PackageManager.PERMISSION_GRANTED

    private fun requestAudioAccess(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        when {
            hasAudioAccess() -> result.success(true)
            activity == null -> result.success(false)
            pendingPermission != null -> result.error(
                "busy", "A permission request is already open", null,
            )
            else -> {
                pendingPermission = result
                activity.requestPermissions(arrayOf(audioPermission), PERMISSION_REQUEST)
            }
        }
    }

    private val permissionListener =
        io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener {
                code, _, results ->
            if (code != PERMISSION_REQUEST) return@RequestPermissionsResultListener false
            val granted = results.isNotEmpty() &&
                results[0] == PackageManager.PERMISSION_GRANTED
            pendingPermission?.success(granted)
            pendingPermission = null
            true
        }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(permissionListener)
        binding.addActivityResultListener(activityResultListener)
    }

    private fun releaseActivity() {
        activityBinding?.removeRequestPermissionsResultListener(permissionListener)
        activityBinding?.removeActivityResultListener(activityResultListener)
        activityBinding = null
    }

    // The recreated activity receives the answer, so open requests stay open.
    override fun onDetachedFromActivityForConfigChanges() = releaseActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        releaseActivity()
        // Nothing can answer a request once its activity is gone. Left open,
        // a delete would keep the library's mutation lock forever and refuse
        // every later request as busy.
        pendingPermission?.success(false)
        pendingPermission = null
        pendingDelete?.success(false)
        pendingDelete = null
    }

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
            "hasAudioAccess" -> result.success(hasAudioAccess())
            "requestAudioAccess" -> requestAudioAccess(result)
            "deleteMediaFiles" -> deleteMediaFiles(
                call.argument<List<String>>("paths").orEmpty(),
                result,
            )
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

    private companion object {
        const val PERMISSION_REQUEST = 7301
        const val DELETE_REQUEST = 7302
    }
}
