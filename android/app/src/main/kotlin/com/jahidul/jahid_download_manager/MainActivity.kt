package com.jahidul.jahid_download_manager

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.jahidul.jdm/files"
        private const val COMPLETION_CHANNEL = "jdm_download_complete"
        private const val NOTIFICATION_PERMISSION_REQUEST = 9038
    }

    private var pendingNotificationPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "supportsPublicDownloads" ->
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    "requestCompletionNotifications" -> requestCompletionPermission(result)
                    "notifyDownloadCompleted" -> {
                        val id = call.argument<String>("id")
                        val fileName = call.argument<String>("fileName")
                        if (id.isNullOrBlank() || fileName.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENTS", "Missing notification details", null)
                        } else {
                            try {
                                result.success(showDownloadCompleted(id, fileName))
                            } catch (failure: Exception) {
                                result.error("NOTIFICATION_FAILED", failure.message, null)
                            }
                        }
                    }
                    "exportToDownloads" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENTS", "Missing file path or name", null)
                            return@setMethodCallHandler
                        }
                        // Stream on a worker thread; Flutter results return
                        // on Android's main thread.
                        Thread {
                            try {
                                val uri = exportToDownloads(sourcePath, fileName)
                                runOnUiThread { result.success(uri.toString()) }
                            } catch (failure: Exception) {
                                runOnUiThread {
                                    result.error("EXPORT_FAILED", failure.message, null)
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestCompletionPermission(result: MethodChannel.Result) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            result.success(notificationsAllowed(manager))
            return
        }
        if (pendingNotificationPermission != null) {
            result.error("PERMISSION_BUSY", "Notification request already running", null)
            return
        }
        pendingNotificationPermission = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationPermission?.success(granted)
        pendingNotificationPermission = null
    }

    private fun showDownloadCompleted(id: String, fileName: String): Boolean {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (!notificationsAllowed(manager)) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) return false

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    COMPLETION_CHANNEL,
                    "Completed downloads",
                    NotificationManager.IMPORTANCE_DEFAULT
                )
            )
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, COMPLETION_CHANNEL)
        } else {
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Download complete")
            .setContentText(fileName.take(200))
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        manager.notify(id, 4100, notification)
        return true
    }

    private fun notificationsAllowed(manager: NotificationManager): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.N ||
            manager.areNotificationsEnabled()

    private fun exportToDownloads(sourcePath: String, requestedName: String): Uri {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException(
                "Direct public Downloads export requires Android 10 or newer"
            )
        }
        val file = File(sourcePath).canonicalFile
        val appRoots = listOfNotNull(applicationContext.dataDir, getExternalFilesDir(null))
        val insideApp = appRoots.any { root ->
            file.path.startsWith(root.canonicalPath + File.separator)
        }
        if (!insideApp || !file.isFile || file.length() <= 0L) {
            throw IOException("Source must be a nonempty file in JDM app storage")
        }
        val name = requestedName.trim()
        if (name != File(name).name || name == "." || name == ".." ||
            name.contains('\\') || name.any { it.code < 32 }
        ) {
            throw IOException("Invalid destination file name")
        }

        val suffix = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(suffix)
            ?: "application/octet-stream"
        val resolver = applicationContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH,
                Environment.DIRECTORY_DOWNLOADS + "/JDM/")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(
            MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values
        ) ?: throw IOException("MediaStore could not create a Downloads entry")

        try {
            file.inputStream().buffered().use { input ->
                (resolver.openOutputStream(uri, "w")
                    ?: throw IOException("Could not open destination")).use { output ->
                    input.copyTo(output, 64 * 1024)
                }
            }
            val complete = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            if (resolver.update(uri, complete, null, null) < 1) {
                throw IOException("Could not finish the Downloads entry")
            }
            return uri
        } catch (failure: Exception) {
            // Never expose a partially written entry or delete the original.
            resolver.delete(uri, null, null)
            throw failure
        }
    }
}
