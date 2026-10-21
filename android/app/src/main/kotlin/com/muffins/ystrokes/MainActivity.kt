package com.muffins.ystrokes

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * 导出落盘的原生能力。
 *
 * 有两件事在 Dart 侧做不到，必须落到平台：
 * 1. **公共下载目录**。Android 10（API 29）起，应用私有目录之外的位置只能通过
 *    MediaStore 写入；`getDownloadsDirectory()` 在 Android 上返回 null 正是这个原因。
 * 2. **目录选择**。系统目录选择器返回的是 SAF 树 URI（`content://`），不是文件系统
 *    路径，写入同样要走 ContentResolver。
 *
 * 约定：方法不可用时返回 `false` / `null` 而不是抛错，让 Dart 侧能安全回落到文件路径。
 */
class MainActivity : FlutterActivity() {

    /** 等待系统目录选择结果的回调；同一时刻只允许一个。 */
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handleCall(call, result) }
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "canSaveToPublicDownloads" -> result.success(canWritePublicDownloads())
                "saveToDownloads" -> saveToDownloads(call, result)
                "pickDirectory" -> pickDirectory(result)
                "saveToDirectoryTree" -> saveToDirectoryTree(call, result)
                else -> result.notImplemented()
            }
        } catch (error: SecurityException) {
            result.error(
                "permission_denied",
                "没有写入权限：若使用的是旧系统，请在系统设置中授予存储权限，或改用「选择目录」",
                null
            )
        } catch (error: Exception) {
            result.error("export_failed", error.message ?: error.toString(), null)
        }
    }

    // ---- 公共下载目录 ----

    private fun canWritePublicDownloads(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q || hasLegacyWritePermission()

    private fun hasLegacyWritePermission(): Boolean =
        checkCallingOrSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED

    private fun saveToDownloads(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("缺少文件内容")
        val fileName = call.argument<String>("fileName")
            ?: throw IllegalArgumentException("缺少文件名")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        val subdir = call.argument<String>("subdir") ?: DEFAULT_SUBDIR

        val relativeDir = "${Environment.DIRECTORY_DOWNLOADS}/$subdir"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val uri = writeViaMediaStore(bytes, fileName, mimeType, relativeDir)
            result.success(
                mapOf("uri" to uri.toString(), "location" to relativeDir)
            )
            return
        }

        // Android 9 及以下：公共目录就是普通文件路径，但需要存储权限。
        if (!hasLegacyWritePermission()) {
            throw SecurityException("legacy write permission missing")
        }
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            subdir
        )
        if (!dir.exists() && !dir.mkdirs()) {
            throw IOException("无法创建下载子目录：${dir.absolutePath}")
        }
        val target = uniqueFile(dir, fileName)
        target.writeBytes(bytes)
        // 让文件管理器 / 相册立刻看到，否则要等一次媒体扫描。
        MediaScannerConnection.scanFile(
            applicationContext,
            arrayOf(target.absolutePath),
            arrayOf(mimeType),
            null
        )
        result.success(
            mapOf(
                "uri" to Uri.fromFile(target).toString(),
                "location" to relativeDir
            )
        )
    }

    /**
     * API 29+：插入待定记录 → 写入 → 取消待定，避免半截文件被其他应用看到。
     * 返回最终的内容 URI。
     */
    private fun writeViaMediaStore(
        bytes: ByteArray,
        fileName: String,
        mimeType: String,
        relativeDir: String
    ): Uri {
        val resolver = applicationContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, relativeDir)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values)
            ?: throw IOException("无法在公共下载目录创建文件")

        try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IOException("无法打开输出流")
        } catch (error: Exception) {
            // 写失败就删掉占位记录，别在下载目录留下一个 0 字节文件。
            resolver.delete(uri, null, null)
            throw error
        }

        val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
        resolver.update(uri, done, null, null)
        return uri
    }

    /** 同秒多次导出时避免覆盖（与 Dart 侧的文件命名策略一致）。 */
    private fun uniqueFile(dir: File, fileName: String): File {
        var candidate = File(dir, fileName)
        if (!candidate.exists()) return candidate

        val dot = fileName.lastIndexOf('.')
        val base = if (dot > 0) fileName.substring(0, dot) else fileName
        val ext = if (dot > 0) fileName.substring(dot) else ""
        var index = 2
        while (candidate.exists()) {
            candidate = File(dir, "$base-$index$ext")
            index++
        }
        return candidate
    }

    // ---- 目录选择（SAF） ----

    private fun pickDirectory(result: MethodChannel.Result) {
        val existing = pendingPick
        if (existing != null) {
            result.error("busy", "目录选择器已经打开", null)
            return
        }
        pendingPick = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQ_PICK_DIR)
        } catch (error: Exception) {
            pendingPick = null
            throw error
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQ_PICK_DIR) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val pending = pendingPick
        pendingPick = null
        if (pending == null) return

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // 用户取消：返回 null，Dart 侧保持原来的位置。
            pending.success(null)
            return
        }

        // 拿持久化授权，否则重启应用后这个目录就写不进去了。
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: SecurityException) {
            // 少数设备/目录不支持持久化，本次仍可写，只是下次要重选。
        }

        pending.success(mapOf("uri" to uri.toString(), "label" to describeTree(uri)))
    }

    private fun saveToDirectoryTree(call: MethodCall, result: MethodChannel.Result) {
        val treeUriString = call.argument<String>("treeUri")
            ?: throw IllegalArgumentException("缺少目录 URI")
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("缺少文件内容")
        val fileName = call.argument<String>("fileName")
            ?: throw IllegalArgumentException("缺少文件名")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"

        val treeUri = Uri.parse(treeUriString)
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri)
        )
        // createDocument 遇到同名文件会由系统自动改名（追加 (1)），不需要自己处理。
        val created = DocumentsContract.createDocument(
            contentResolver,
            parentUri,
            mimeType,
            fileName
        ) ?: throw IOException("无法在所选目录创建文件")

        try {
            contentResolver.openOutputStream(created)?.use { it.write(bytes) }
                ?: throw IOException("无法打开所选目录的输出流")
        } catch (error: Exception) {
            DocumentsContract.deleteDocument(contentResolver, created)
            throw error
        }

        result.success(
            mapOf(
                "uri" to created.toString(),
                "location" to describeTree(treeUri)
            )
        )
    }

    /** 取目录树的显示名（通常是「下载」「Documents」这样的系统名）。 */
    private fun describeTree(treeUri: Uri): String {
        return try {
            val docUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri)
            )
            val name = contentResolver.query(
                docUri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
            name ?: (treeUri.lastPathSegment ?: "所选目录")
        } catch (_: Exception) {
            treeUri.lastPathSegment ?: "所选目录"
        }
    }

    companion object {
        private const val CHANNEL = "com.muffins.ystrokes/export"
        private const val REQ_PICK_DIR = 4701
        private const val DEFAULT_SUBDIR = "YStrokes"
    }
}
