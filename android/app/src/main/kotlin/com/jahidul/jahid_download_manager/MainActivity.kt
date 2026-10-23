package com.jahidul.jahid_download_manager

import android.content.ContentValues
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
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "exportToDownloads") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val sourcePath = call.argument<String>("sourcePath")
                val fileName = call.argument<String>("fileName")
                if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENTS", "Missing file path or name", null)
                    return@setMethodCallHandler
                }
                // Use a worker thread for multi-gigabyte files; MethodChannel
                // callbacks return to Flutter on the Android main thread.
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
    }

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
