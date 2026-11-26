import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secret storage for provider and System One API keys.
///
/// Business Rule:
/// 1. Keys are written only to platform secure storage (Android Keystore /
///    iOS Keychain); they never touch SharedPreferences, AppStorage or logs.
/// 2. Logging call sites must use [maskKey]; raw keys must never be printed.
class KeyStore {
  KeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String providerKey(String providerId) => 'key_$providerId';

  Future<String> read(String key) async {
    try {
      return await _storage.read(key: key) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> write(String key, String value) async {
    final String trimmed = value.trim();
    try {
      if (trimmed.isEmpty) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: trimmed);
      }
    } catch (_) {
      // Fail closed: the caller surfaces "not configured" on the next read.
    }
  }

  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // Ignore; a missing key is equivalent to an empty value.
    }
  }
}

/// Reason: logs and UI hints must never expose a full credential.
String maskKey(String key) {
  final String k = key.trim();
  if (k.length <= 6) {
    return '***';
  }
  return '${k.substring(0, 3)}***${k.substring(k.length - 2)}';
}
