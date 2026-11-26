import 'package:balance_app/data/services/apk_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isApkUrl', () {
    test('accepts http(s) apk links', () {
      expect(
        ApkUpdateService.isApkUrl('https://gitee.com/x/releases/download/v1/a.apk'),
        true,
      );
      expect(
        ApkUpdateService.isApkUrl('https://example.com/a.APK?token=1'),
        true,
      );
    });

    test('rejects release pages and non-http schemes', () {
      expect(
        ApkUpdateService.isApkUrl('https://gitee.com/aishangwuji/openchat/releases'),
        false,
      );
      expect(ApkUpdateService.isApkUrl('file:///sdcard/a.apk'), false);
      expect(ApkUpdateService.isApkUrl(''), false);
      expect(ApkUpdateService.isApkUrl('not a url'), false);
    });
  });

  group('apkFileName', () {
    test('builds a safe file name from the version', () {
      expect(ApkUpdateService.apkFileName('1.2.3'), 'openchat-1.2.3.apk');
      expect(ApkUpdateService.apkFileName('v1.2.3'), 'openchat-v1.2.3.apk');
    });

    test('strips path separators, spaces and leading dots', () {
      expect(
        ApkUpdateService.apkFileName('../../evil 1.0'),
        'openchat-evil1.0.apk',
      );
      expect(ApkUpdateService.apkFileName('  '), 'openchat-update.apk');
    });
  });

  group('ApkDownloadState', () {
    test('clamps progress and handles unknown total', () {
      const ApkDownloadState running = ApkDownloadState(
        status: ApkDownloadStatus.running,
        received: 50,
        total: 200,
      );
      expect(running.progress, closeTo(0.25, 0.0001));
      expect(running.isActive, true);
      expect(running.percentLabel, '25%');

      const ApkDownloadState unknown =
          ApkDownloadState(status: ApkDownloadStatus.running, received: 10);
      expect(unknown.hasTotal, false);
      expect(unknown.progress, 0);

      const ApkDownloadState overflow = ApkDownloadState(
        status: ApkDownloadStatus.running,
        received: 300,
        total: 200,
      );
      expect(overflow.progress, 1);
    });

    test('formatBytes switches units', () {
      expect(formatBytes(0), '0 MB');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    });
  });
}
