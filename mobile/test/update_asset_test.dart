import 'package:balance_app/data/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('picks the APK even when a HAP asset comes first', () {
    final String asset = UpdateService.pickDownloadAsset(<Object?>[
      <String, Object>{
        'browser_download_url': 'https://example.com/openchat-1.0.2.hap',
      },
      <String, Object>{
        'browser_download_url': 'https://example.com/openchat-1.0.2.apk',
      },
    ]);
    expect(asset, 'https://example.com/openchat-1.0.2.apk');
  });

  test('falls back to the first asset when no APK is attached', () {
    final String asset = UpdateService.pickDownloadAsset(<Object?>[
      <String, Object>{
        'browser_download_url': 'https://example.com/openchat-1.0.2.zip',
      },
    ]);
    expect(asset, 'https://example.com/openchat-1.0.2.zip');
  });

  test('ignores malformed or missing assets', () {
    expect(UpdateService.pickDownloadAsset(null), '');
    expect(
      UpdateService.pickDownloadAsset(<Object?>[
        <String, Object>{'browser_download_url': 1},
        'not-a-map',
      ]),
      '',
    );
  });
}
