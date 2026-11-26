import 'package:flutter/material.dart';

import '../../data/services/apk_update_service.dart';

/// 下载完成后自动拉起系统安装页（用户要求「下载完直接触发安装页面」）。
///
/// Business Rule: 只在应用处于前台时拉起——Android 10+ 限制后台启动 Activity，
/// 后台下完不会硬弹；下载本身由系统 DownloadManager 负责，不会被中断，
/// 用户回到应用（resumed）时立刻补一次安装。
class UpdateInstallHost extends StatefulWidget {
  const UpdateInstallHost({super.key, required this.child});

  final Widget child;

  @override
  State<UpdateInstallHost> createState() => _UpdateInstallHostState();
}

class _UpdateInstallHostState extends State<UpdateInstallHost>
    with WidgetsBindingObserver {
  /// 已经为哪个 downloadId 拉起过安装器（防止从安装页返回时重复弹）。
  int _installedId = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ApkUpdateService.state.addListener(_onStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onStateChanged());
  }

  @override
  void dispose() {
    ApkUpdateService.state.removeListener(_onStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onStateChanged();
    }
  }

  void _onStateChanged() {
    if (!mounted) {
      return;
    }
    final ApkDownloadState current = ApkUpdateService.state.value;
    if (!current.isCompleted || current.id == _installedId) {
      return;
    }
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _launchInstaller(current.id);
  }

  Future<void> _launchInstaller(int id) async {
    _installedId = id;
    final ApkInstallOutcome outcome = await installDownloadedUpdate(context);
    if (!mounted) {
      return;
    }
    if (outcome == ApkInstallOutcome.needPermission ||
        outcome == ApkInstallOutcome.failed) {
      // 授权后可重试：清掉标记，回到前台时再试一次。
      _installedId = -1;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 拉起系统安装页；缺权限时弹引导，其余失败给出可读提示。
Future<ApkInstallOutcome> installDownloadedUpdate(BuildContext context) async {
  final ApkInstallOutcome outcome = await ApkUpdateService.install();
  if (!context.mounted) {
    return outcome;
  }
  switch (outcome) {
    case ApkInstallOutcome.needPermission:
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('需要允许安装应用'),
          content: const Text(
            '系统要求先允许 openchat 安装未知来源的应用。允许后回到应用会自动继续安装。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                ApkUpdateService.openInstallSettings();
              },
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      break;
    case ApkInstallOutcome.fileMissing:
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('安装包不可用'),
          content: const Text('下载的安装包已被清理，请重新检查更新并下载。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      break;
    case ApkInstallOutcome.failed:
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('打开安装页失败，请稍后重试')),
      );
      break;
    case ApkInstallOutcome.started:
    case ApkInstallOutcome.unsupported:
      break;
  }
  return outcome;
}
