import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 应用内更新下载（Android）——与原生 `ApkUpdateChannel` 对应。
///
/// 为什么走系统 DownloadManager：后台继续下载、进程被杀也能下完、通知栏可见进度；
/// 安装由原生侧用 FileProvider + ACTION_VIEW 交给系统包安装器。
class ApkDownloadStatus {
  const ApkDownloadStatus._();

  static const String idle = 'idle';
  static const String pending = 'pending';
  static const String running = 'running';
  static const String paused = 'paused';
  static const String completed = 'completed';
  static const String failed = 'failed';
  static const String cancelled = 'cancelled';
}

@immutable
class ApkDownloadState {
  const ApkDownloadState({
    this.id = -1,
    this.status = ApkDownloadStatus.idle,
    this.received = 0,
    this.total = 0,
    this.error,
  });

  final int id;
  final String status;
  final int received;
  final int total;
  final String? error;

  bool get isActive =>
      status == ApkDownloadStatus.pending ||
      status == ApkDownloadStatus.running ||
      status == ApkDownloadStatus.paused;

  bool get isCompleted => status == ApkDownloadStatus.completed;

  /// 0..1；总量未知（服务端没给 Content-Length）时返回 0，UI 改用不确定进度条。
  double get progress {
    if (total <= 0) {
      return 0;
    }
    final double ratio = received / total;
    return ratio.isFinite ? ratio.clamp(0.0, 1.0) : 0;
  }

  bool get hasTotal => total > 0;

  String get sizeLabel {
    if (!hasTotal) {
      return formatBytes(received);
    }
    return '${formatBytes(received)} / ${formatBytes(total)}';
  }

  String get percentLabel =>
      hasTotal ? '${(progress * 100).toStringAsFixed(0)}%' : '';
}

/// 拉起安装器的结果。
enum ApkInstallOutcome {
  /// 系统安装页已打开。
  started,

  /// 没有「安装未知应用」权限，需要引导用户去系统设置。
  needPermission,

  /// 下载文件不存在（被清理或下载未完成）。
  fileMissing,

  /// 其他失败（FileProvider 或 Intent 异常）。
  failed,

  /// 当前平台不支持应用内安装（非 Android）。
  unsupported,
}

class ApkUpdateService {
  ApkUpdateService._();

  static const MethodChannel _method =
      MethodChannel('com.aishangwuji.openchat/apk_update');
  static const EventChannel _events =
      EventChannel('com.aishangwuji.openchat/apk_update_progress');

  /// 全局下载状态：设置页进度行、下载面板、自动安装宿主都监听它。
  static final ValueNotifier<ApkDownloadState> state =
      ValueNotifier<ApkDownloadState>(const ApkDownloadState());

  static StreamSubscription<dynamic>? _subscription;

  /// 只有 Android 有系统包安装器；iOS 只能跳 App Store，HarmonyOS 不允许三方装 HAP。
  static bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> canInstallPackages() async {
    if (!isSupported) {
      return false;
    }
    try {
      final bool? allowed =
          await _method.invokeMethod<bool>('canInstallPackages');
      return allowed ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 启动下载；返回 DownloadManager 的 id，失败返回 null。
  static Future<int?> startDownload({
    required String url,
    required String fileName,
  }) async {
    if (!isSupported) {
      return null;
    }
    _listen();
    try {
      final int? id = await _method.invokeMethod<int>('startDownload', {
        'url': url,
        'fileName': fileName,
      });
      if (id == null || id < 0) {
        return null;
      }
      state.value = ApkDownloadState(id: id, status: ApkDownloadStatus.pending);
      return id;
    } on PlatformException catch (error) {
      debugPrint('ApkUpdateService: start failed ${error.code}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> cancel() async {
    if (!isSupported) {
      return;
    }
    try {
      await _method.invokeMethod<bool>('cancel');
    } on PlatformException {
      // 取消失败不阻塞 UI；状态由原生事件覆盖。
    } on MissingPluginException {
      // 同上。
    }
  }

  /// 拉起系统安装页。
  static Future<ApkInstallOutcome> install() async {
    if (!isSupported) {
      return ApkInstallOutcome.unsupported;
    }
    try {
      final String? outcome = await _method.invokeMethod<String>('install');
      switch (outcome) {
        case 'started':
          return ApkInstallOutcome.started;
        case 'need_permission':
          return ApkInstallOutcome.needPermission;
        case 'file_missing':
          return ApkInstallOutcome.fileMissing;
        default:
          return ApkInstallOutcome.failed;
      }
    } on PlatformException {
      return ApkInstallOutcome.failed;
    } on MissingPluginException {
      return ApkInstallOutcome.unsupported;
    }
  }

  /// 打开系统「安装未知应用」授权页。
  static Future<void> openInstallSettings() async {
    if (!isSupported) {
      return;
    }
    try {
      await _method.invokeMethod<bool>('openInstallSettings');
    } on PlatformException {
      // 部分 ROM 无此页，忽略。
    } on MissingPluginException {
      // 同上。
    }
  }

  static void _listen() {
    if (_subscription != null) {
      return;
    }
    _subscription = _events.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is! Map) {
          return;
        }
        final Map<Object?, Object?> raw = event;
        final int id = raw['id'] is int ? raw['id']! as int : -1;
        final String status =
            raw['status'] is String ? raw['status']! as String : '';
        if (status.isEmpty) {
          return;
        }
        state.value = ApkDownloadState(
          id: id,
          status: status,
          received: raw['received'] is int ? raw['received']! as int : 0,
          total: raw['total'] is int ? raw['total']! as int : 0,
          error: raw['error'] is String ? raw['error']! as String : null,
        );
      },
      onError: (Object error) {
        debugPrint('ApkUpdateService: progress stream error $error');
      },
    );
  }

  /// 只有 `.apk` 直链才在应用内下载；release 页面等非直链仍交给浏览器。
  static bool isApkUrl(String url) {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      return false;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return false;
    }
    return uri.path.toLowerCase().endsWith('.apk');
  }

  /// 下载文件名：`openchat-<version>.apk`，非法字符剔除，避免路径穿越/隐藏文件。
  static String apkFileName(String version) {
    String cleaned = version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '');
    cleaned = cleaned.replaceFirst(RegExp(r'^\.+'), '');
    final String base = cleaned.isEmpty ? 'update' : cleaned;
    return 'openchat-$base.apk';
  }
}

/// 人类可读体积（1 位小数）。
String formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 MB';
  }
  const double kb = 1024;
  const double mb = kb * 1024;
  final double value = bytes.toDouble();
  if (value >= mb) {
    return '${(value / mb).toStringAsFixed(1)} MB';
  }
  if (value >= kb) {
    return '${(value / kb).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}
