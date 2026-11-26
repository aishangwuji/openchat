import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/services/apk_update_service.dart';
import 'update_install_host.dart';

/// 应用内更新下载面板：进度条 + 体积/百分比 + 后台下载/取消。
///
/// 下载交给系统 DownloadManager，点「后台下载」只是收起面板，下载继续；
/// 完成后面板提供「立即安装」，宿主 [UpdateInstallHost] 也会在前台自动拉起安装页。
Future<void> showApkDownloadSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.colors.surface,
    builder: (BuildContext _) => const ApkDownloadSheet(),
  );
}

class ApkDownloadSheet extends StatelessWidget {
  const ApkDownloadSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return SafeArea(
      child: ValueListenableBuilder<ApkDownloadState>(
        valueListenable: ApkUpdateService.state,
        builder: (BuildContext context, ApkDownloadState state, Widget? _) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _title(state),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: c.textTitle,
                  ),
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: state.hasTotal ? state.progress : null,
                    minHeight: 8,
                    backgroundColor: c.fill,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _detail(state),
                  style: TextStyle(fontSize: 12, color: c.textMuted),
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    if (state.isActive) ...<Widget>[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('后台下载'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            ApkUpdateService.cancel();
                            Navigator.of(context).pop();
                          },
                          child: const Text('取消下载'),
                        ),
                      ),
                    ] else if (state.isCompleted) ...<Widget>[
                      Expanded(
                        child: FilledButton(
                          onPressed: () => installDownloadedUpdate(context),
                          child: const Text('立即安装'),
                        ),
                      ),
                    ] else ...<Widget>[
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('关闭'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _title(ApkDownloadState state) {
    switch (state.status) {
      case ApkDownloadStatus.completed:
        return '更新包已下载';
      case ApkDownloadStatus.failed:
        return '下载失败';
      case ApkDownloadStatus.cancelled:
        return '已取消下载';
      case ApkDownloadStatus.paused:
        return '下载已暂停';
      default:
        return '正在下载更新';
    }
  }

  String _detail(ApkDownloadState state) {
    if (state.isActive) {
      final String percent = state.percentLabel;
      return percent.isEmpty
          ? '已下载 ${state.sizeLabel}'
          : '${state.sizeLabel} · $percent';
    }
    if (state.isCompleted) {
      return '点「立即安装」打开系统安装页；也可以直接等它自动弹出。';
    }
    if (state.status == ApkDownloadStatus.failed) {
      return state.error ?? '请检查网络后重试';
    }
    return '下载已停止。';
  }
}
