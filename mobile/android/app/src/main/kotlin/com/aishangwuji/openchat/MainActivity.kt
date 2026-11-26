package com.aishangwuji.openchat

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * FragmentActivity is required by local_auth so the biometric / device
 * credential prompt can be hosted on top of the Flutter view.
 *
 * 同时在这里挂应用内更新通道：下载走系统 DownloadManager，安装交给系统包安装器
 * （见 [ApkUpdateChannel]）。
 */
class MainActivity : FlutterFragmentActivity() {
    private var apkUpdateChannel: ApkUpdateChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val channel = ApkUpdateChannel(this)
        apkUpdateChannel = channel
        MethodChannel(messenger, ApkUpdateChannel.METHOD_CHANNEL).setMethodCallHandler(channel)
        EventChannel(messenger, ApkUpdateChannel.EVENT_CHANNEL).setStreamHandler(channel)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        apkUpdateChannel?.let { channel ->
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                ApkUpdateChannel.METHOD_CHANNEL
            ).setMethodCallHandler(null)
            EventChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                ApkUpdateChannel.EVENT_CHANNEL
            ).setStreamHandler(null)
        }
        apkUpdateChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
