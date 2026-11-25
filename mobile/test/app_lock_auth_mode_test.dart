import 'package:balance_app/data/services/key_store.dart';
import 'package:balance_app/data/services/preferences_service.dart';
import 'package:balance_app/state/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SettingsController> _load() async {
  final PreferencesService prefs = await PreferencesService.load();
  return SettingsController.load(prefs: prefs, keyStore: KeyStore());
}

void main() {
  test('app lock auth mode defaults to any', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsController settings = await _load();
    expect(settings.appLockAuthMode, appLockAuthAny);
  });

  test('app lock auth mode persists biometric choice', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsController settings = await _load();
    await settings.setAppLockAuthMode(appLockAuthBiometric);
    expect(settings.appLockAuthMode, appLockAuthBiometric);

    final SettingsController reloaded = await _load();
    expect(reloaded.appLockAuthMode, appLockAuthBiometric);
  });

  test('app lock auth mode rejects values it cannot enforce', () async {
    // HarmonyOS-only values (face/fingerprint/password) must not leak into the
    // mobile model: local_auth can only enforce "biometrics vs password fallback".
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_lock_auth_mode': 'face',
    });
    final SettingsController settings = await _load();
    expect(settings.appLockAuthMode, appLockAuthAny);

    await settings.setAppLockAuthMode('password');
    expect(settings.appLockAuthMode, appLockAuthAny);
  });
}
