package com.aishangwuji.openchat

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内 APK 下载 + 拉起系统安装页（Android 端）。
 *
 * 为什么用系统 DownloadManager 而不是自己拉流：
 * - 后台继续下载、断网/切后台不中断，通知栏可见进度（用户要求的「允许后台下载」）；
 * - 目标目录是应用私有外部目录（getExternalFilesDir/DOWNLOADS），不需要存储权限；
 * - 进程被杀后下载仍在继续，重启后系统通知里仍能看到结果。
 *
 * 安装走 ACTION_VIEW + FileProvider 授权读，交给系统包安装器（就是用户说的「安装页面」）；
 * 没有「安装未知应用」权限时返回 need_permission，由 Dart 侧引导去系统设置，不静默失败。
 */
class ApkUpdateChannel(private val activity: Activity) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.aishangwuji.openchat/apk_update"
        const val EVENT_CHANNEL = "com.aishangwuji.openchat/apk_update_progress"
        private const val APK_MIME = "application/vnd.android.package-archive"
        private const val POLL_INTERVAL_MS = 300L
        private const val USER_AGENT = "openchat-mobile-updater"
    }

    private val downloadManager: DownloadManager =
        activity.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null
    private var downloadId: Long = -1L
    private var targetFile: File? = null

    private val poller = object : Runnable {
        override fun run() {
            if (sink == null || downloadId < 0) {
                return
            }
            if (emitProgress()) {
                mainHandler.postDelayed(this, POLL_INTERVAL_MS)
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startDownload" -> {
                val url = call.argument<String>("url")
                val fileName = call.argument<String>("fileName")
                if (url.isNullOrBlank() || fileName.isNullOrBlank()) {
                    result.error("bad_args", "url and fileName are required", null)
                    return
                }
                result.success(startDownload(url, fileName))
            }
            "cancel" -> {
                cancelDownload()
                result.success(true)
            }
            "install" -> result.success(install())
            "canInstallPackages" -> result.success(canInstallPackages())
            "openInstallSettings" -> {
                openInstallSettings()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (downloadId >= 0) {
            mainHandler.removeCallbacks(poller)
            if (emitProgress()) {
                mainHandler.postDelayed(poller, POLL_INTERVAL_MS)
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        mainHandler.removeCallbacks(poller)
    }

    private fun startDownload(url: String, fileName: String): Long {
        val dir: File? = activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
        if (dir == null) {
            return -1L
        }
        if (!dir.exists()) {
            dir.mkdirs()
        }
        // 旧包先删掉，避免占用空间也避免装到上一次的残包。
        val file = File(dir, sanitize(fileName))
        if (file.exists() && !file.delete()) {
            // 删不掉也继续：目标文件会被 DownloadManager 覆盖或另存，不影响新下载。
        }
        // 顺手清掉历史更新包（只认本目录里的 openchat-*.apk），不让几十 MB 的旧包常驻。
        dir.listFiles()?.forEach { existing ->
            if (existing.isFile && existing.name != file.name &&
                existing.name.startsWith("openchat-") &&
                existing.name.endsWith(".apk", ignoreCase = true)
            ) {
                existing.delete()
            }
        }
        cancelDownload()
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(file.name)
            .setDescription("openchat 更新包")
            .setMimeType(APK_MIME)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalFilesDir(activity, Environment.DIRECTORY_DOWNLOADS, file.name)
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(false)
            .addRequestHeader("User-Agent", USER_AGENT)
        val id = downloadManager.enqueue(request)
        downloadId = id
        targetFile = file
        mainHandler.removeCallbacks(poller)
        if (sink != null) {
            mainHandler.postDelayed(poller, POLL_INTERVAL_MS)
        }
        return id
    }

    private fun cancelDownload() {
        val id = downloadId
        if (id >= 0) {
            try {
                downloadManager.remove(id)
            } catch (_: Exception) {
                // 已结束的任务 remove 会返回 0，不必上报。
            }
            sink?.success(
                mapOf("id" to id, "status" to "cancelled", "received" to 0, "total" to 0)
            )
        }
        downloadId = -1L
        mainHandler.removeCallbacks(poller)
    }

    /** 返回 true 表示还在下载，需要继续轮询。 */
    private fun emitProgress(): Boolean {
        val events = sink ?: return false
        val id = downloadId
        if (id < 0) {
            return false
        }
        val cursor = downloadManager.query(DownloadManager.Query().setFilterById(id))
            ?: return false
        var active = true
        cursor.use { c ->
            if (!c.moveToFirst()) {
                events.success(
                    mapOf("id" to id, "status" to "failed", "error" to "download record missing")
                )
                active = false
                return@use
            }
            val status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val received = c.getLong(
                c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
            )
            val total = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            val payload = mutableMapOf<String, Any?>(
                "id" to id,
                "received" to received,
                "total" to total
            )
            when (status) {
                DownloadManager.STATUS_SUCCESSFUL -> {
                    payload["status"] = "completed"
                    active = false
                }
                DownloadManager.STATUS_FAILED -> {
                    val reason = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                    payload["status"] = "failed"
                    payload["error"] = "download failed (reason=$reason)"
                    active = false
                }
                DownloadManager.STATUS_PAUSED -> payload["status"] = "paused"
                DownloadManager.STATUS_PENDING -> payload["status"] = "pending"
                else -> payload["status"] = "running"
            }
            events.success(payload)
        }
        if (!active) {
            mainHandler.removeCallbacks(poller)
        }
        return active
    }

    /** 拉起系统包安装器；返回 started / need_permission / file_missing。 */
    private fun install(): String {
        val file = targetFile ?: resolveDownloadedFile()
        if (file == null || !file.exists()) {
            return "file_missing"
        }
        if (!canInstallPackages()) {
            return "need_permission"
        }
        val uri: Uri = try {
            FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
        } catch (error: Exception) {
            return "failed"
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_MIME)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            activity.startActivity(intent)
            "started"
        } catch (error: Exception) {
            "failed"
        }
    }

    private fun canInstallPackages(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        try {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${activity.packageName}")
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
        } catch (_: Exception) {
            // 部分 ROM 没有该设置页，交给用户手动在系统设置里开。
        }
    }

    /** 进程被杀后重启时兜底：从 DownloadManager 记录里找回文件路径。 */
    private fun resolveDownloadedFile(): File? {
        val id = downloadId
        if (id < 0) {
            return null
        }
        val cursor = downloadManager.query(DownloadManager.Query().setFilterById(id)) ?: return null
        cursor.use { c ->
            if (!c.moveToFirst()) {
                return null
            }
            val local = c.getString(
                c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI)
            ) ?: return null
            if (!local.startsWith("file://")) {
                return null
            }
            val path = Uri.parse(local).path ?: return null
            return File(path)
        }
    }

    private fun sanitize(fileName: String): String {
        val cleaned = fileName.replace(Regex("[^0-9A-Za-z._-]"), "").trimStart('.')
        return if (cleaned.endsWith(".apk", ignoreCase = true) && cleaned.length > 4) {
            cleaned
        } else {
            "openchat-update.apk"
        }
    }
}
