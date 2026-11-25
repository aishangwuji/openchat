import 'package:shared_preferences/shared_preferences.dart';

/// Non-secret app preferences.
///
/// Security note: API keys never live here; they are stored through
/// [KeyStore] (Keychain / Android Keystore backed secure storage).
class PreferencesService {
  PreferencesService._(this._prefs);

  final SharedPreferences _prefs;

  static const String keyAppearance = 'app_appearance';
  static const String keySkin = 'skin_id';
  static const String keyFontSizeLevel = 'app_font_size_level';
  static const String keyAutoCollapseThinking = 'auto_collapse_thinking';
  static const String keyAppLanguage = 'app_language';
  static const String keyAppLockEnabled = 'app_lock_enabled';
  /// 应用锁解锁方式：`any`（指纹/面容/密码由系统决定）| `biometric`（仅指纹/面容）。
  static const String keyAppLockAuthMode = 'app_lock_auth_mode';
  static const String keyAddedProviderIds = 'added_provider_ids';
  static const String keyActiveSessionId = 'active_session_id';

  // 工具开关（设置 > 工具）；默认值与鸿蒙端一致：全开，内容安全关闭。
  static const String keyFeatureTitle = 'feature_auto_title';
  static const String keyFeatureFiles = 'feature_files';
  static const String keyFeatureAsr = 'feature_asr';
  static const String keyFeatureTts = 'feature_tts';
  static const String keyFeatureImage = 'feature_image';
  static const String keyFeatureSafety = 'feature_safety';
  static const String keyFeatureReadUrl = 'feature_read_url';
  static const String keyWebSearchProvider = 'web_search_provider';
  static const String keyTtsVoice = 'tts_voice';
  /// 用户所在地（注入 latest_reminder，可留空）。
  static const String keyUserLocation = 'user_location';

  static const String storeCharacters = 'saved_characters';
  static const String storeIdentities = 'saved_identities';
  static const String storeSessions = 'saved_sessions';

  static Future<PreferencesService> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return PreferencesService._(prefs);
  }

  String getString(String key, {String fallback = ''}) =>
      _prefs.getString(key) ?? fallback;

  Future<void> setString(String key, String value) => _prefs.setString(key, value);

  int getInt(String key, {int fallback = 0}) => _prefs.getInt(key) ?? fallback;

  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);

  double getDouble(String key, {double fallback = 0}) =>
      _prefs.getDouble(key) ?? fallback;

  Future<void> setDouble(String key, double value) => _prefs.setDouble(key, value);

  bool getBool(String key, {bool fallback = false}) =>
      _prefs.getBool(key) ?? fallback;

  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);

  Future<void> remove(String key) => _prefs.remove(key);
}
