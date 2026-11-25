import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/app_version.dart';

/// 应用内更新检查（与鸿蒙端 UpdateService 同契约）。
///
/// - 更新源：Gitee Release 优先、GitHub Release 兜底；
/// - tag 形如 `v1.2.3`，与 [appVersion] 逐段数值比较；
/// - 资产只认 `.apk`（HAP 是鸿蒙原生包，Android/卓易通装不了），
///   没有 APK 时回退 release 页面；
/// - 网络失败返回 null，调用方决定是否提示。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.pageUrl,
    required this.downloadUrl,
    required this.source,
  });

  final String version;
  final String notes;
  final String pageUrl;
  final String downloadUrl;
  final String source;
}

class UpdateService {
  static const String _giteeApi =
      'https://gitee.com/api/v5/repos/aishangwuji/openchat/releases/latest';
  static const String _githubApi =
      'https://api.github.com/repos/aishangwuji/openchat/releases/latest';
  static const int _maxNotesChars = 600;

  /// 当前版本（与 pubspec `version:` 保持一致，发布时同步修改）。
  static String get currentVersion => appVersion;

  /// 检查更新；无新版或失败返回 null。
  static Future<UpdateInfo?> check() async {
    UpdateInfo? info = await _fetch(_giteeApi, 'gitee');
    info ??= await _fetch(_githubApi, 'github');
    if (info == null) {
      return null;
    }
    return _compare(info.version, currentVersion) > 0 ? info : null;
  }

  static Future<UpdateInfo?> _fetch(String url, String source) async {
    try {
      final http.Response resp = await http
          .get(Uri.parse(url), headers: <String, String>{
        'Accept': 'application/json',
        'User-Agent': 'openchat-mobile-updater',
      })
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        return null;
      }
      final Object? decoded = jsonDecode(resp.body);
      if (decoded is! Map) {
        return null;
      }
      final Map<String, dynamic> rec = decoded.cast<String, dynamic>();
      final Object? tag = rec['tag_name'];
      if (tag is! String || tag.isEmpty) {
        return null;
      }
      final String version = tag.startsWith('v') || tag.startsWith('V')
          ? tag.substring(1)
          : tag;
      final Object? page = rec['html_url'];
      final Object? body = rec['body'];
      String notes = body is String ? body : '';
      if (notes.length > _maxNotesChars) {
        notes = '${notes.substring(0, _maxNotesChars)}…';
      }
      final String download = pickDownloadAsset(rec['assets']);
      return UpdateInfo(
        version: version,
        notes: notes,
        pageUrl: page is String ? page : '',
        downloadUrl: download.isNotEmpty
            ? download
            : (page is String ? page : ''),
        source: source,
      );
    } catch (error) {
      // 静默失败：更新检查不应影响正常使用。
      return null;
    }
  }

  /// 资产优先级：`.apk` → 第一个可下载链接（通常是 release 页面）。
  ///
  /// Business Rule: 同一 release 可能同时挂 Android APK 与 HarmonyOS HAP。
  /// Android/卓易通只能安装 APK，绝不能因为 HAP 排在前面就选中它。
  @visibleForTesting
  static String pickDownloadAsset(Object? raw) {
    if (raw is! List) {
      return '';
    }
    String apk = '';
    String first = '';
    for (final Object? item in raw) {
      if (item is! Map) {
        continue;
      }
      final Object? url = item['browser_download_url'];
      if (url is! String) {
        continue;
      }
      if (first.isEmpty) {
        first = url;
      }
      final String lower = url.toLowerCase();
      if (apk.isEmpty && lower.endsWith('.apk')) {
        apk = url;
      }
    }
    return apk.isNotEmpty ? apk : first;
  }

  /// 逐段数值比较：1.2.10 > 1.2.9；非法段按 0 处理。
  static int _compare(String a, String b) {
    final List<int> pa = _parts(a);
    final List<int> pb = _parts(b);
    final int len = pa.length > pb.length ? pa.length : pb.length;
    for (int i = 0; i < len; i++) {
      final int va = i < pa.length ? pa[i] : 0;
      final int vb = i < pb.length ? pb[i] : 0;
      if (va > vb) {
        return 1;
      }
      if (va < vb) {
        return -1;
      }
    }
    return 0;
  }

  static List<int> _parts(String value) {
    final String text =
        value.trim().replaceFirst(RegExp(r'^v', caseSensitive: false), '');
    return text
        .split('.')
        .map((String p) => int.tryParse(p) ?? 0)
        .toList(growable: false);
  }
}
