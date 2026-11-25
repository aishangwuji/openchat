import 'package:flutter/material.dart';

import '../data/models/chat_models.dart';
import '../data/services/key_store.dart';
import '../core/theme/app_skins.dart';
import '../data/services/preferences_service.dart';

/// 联网搜索来源：'deepseek'（服务端内置工具）| 'baizhi'（百智云 OpenAPI）。
const String webSearchProviderDeepseek = 'deepseek';
const String webSearchProviderBaizhi = 'baizhi';

/// 应用锁解锁方式：`any` 允许指纹/面容/密码兜底；`biometric` 仅指纹/面容。
/// Business Rule: 移动端系统弹窗不暴露「只许面容」「只许指纹」，因此只分两档；
///   具体用哪种生物识别仍由系统决定。
const String appLockAuthAny = 'any';
const String appLockAuthBiometric = 'biometric';

const List<double> fontScaleLevels = <double>[
  0.85,
  0.92,
  1.0,
  1.08,
  1.16,
  1.25,
  1.35,
];

class SettingsController extends ChangeNotifier {
  SettingsController({
    required PreferencesService prefs,
    required KeyStore keyStore,
  })  : _prefs = prefs,
        _keyStore = keyStore;

  final PreferencesService _prefs;
  final KeyStore _keyStore;

  String _appearance = 'system';
  String _skinId = defaultSkinId;
  int _fontLevel = 3;
  bool _autoCollapseThinking = true;
  String _language = 'zh-CN';
  bool _appLockEnabled = false;
  bool _appLocked = false;
  String _appLockAuthMode = appLockAuthAny;

  // 工具开关（设置 > 工具）：默认与鸿蒙端一致。
  bool _featureTitle = true;
  bool _featureFiles = true;
  bool _featureAsr = true;
  bool _featureTts = true;
  bool _featureImage = true;
  bool _featureSafety = false;
  bool _featureReadUrl = true;
  String _webSearchProvider = webSearchProviderDeepseek;
  String _ttsVoice = 'stella';
  /// 用户所在地：随 latest_reminder 告诉模型，可留空。
  String _userLocation = '';

  String get appearance => _appearance;
  String get skinId => _skinId;
  AppSkin get skin => skinById(_skinId);
  int get fontLevel => _fontLevel;
  double get fontScale =>
      fontScaleLevels[(_fontLevel - 1).clamp(0, 6).toInt()];
  bool get autoCollapseThinking => _autoCollapseThinking;
  String get language => _language;
  bool get appLockEnabled => _appLockEnabled;
  bool get appLocked => _appLocked;
  String get appLockAuthMode => _appLockAuthMode;
  bool get featureTitle => _featureTitle;
  bool get featureFiles => _featureFiles;
  bool get featureAsr => _featureAsr;
  bool get featureTts => _featureTts;
  bool get featureImage => _featureImage;
  bool get featureSafety => _featureSafety;
  bool get featureReadUrl => _featureReadUrl;
  String get webSearchProvider => _webSearchProvider;
  String get ttsVoice => _ttsVoice;
  String get userLocation => _userLocation;

  ThemeMode get themeMode {
    switch (_appearance) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static Future<SettingsController> load({
    required PreferencesService prefs,
    required KeyStore keyStore,
  }) async {
    final SettingsController c = SettingsController(
      prefs: prefs,
      keyStore: keyStore,
    );
    c._appearance = _validAppearance(
      prefs.getString(PreferencesService.keyAppearance, fallback: 'system'),
    );
    final int level = prefs.getInt(PreferencesService.keyFontSizeLevel, fallback: 3);
    c._fontLevel = level.clamp(1, 7);
    c._autoCollapseThinking =
        prefs.getBool(PreferencesService.keyAutoCollapseThinking, fallback: true);
    final String lang =
        prefs.getString(PreferencesService.keyAppLanguage, fallback: 'zh-CN');
    c._skinId = skinById(
      prefs.getString(PreferencesService.keySkin, fallback: defaultSkinId),
    ).id;
    c._language = lang == 'en-US' ? 'en-US' : 'zh-CN';
    c._appLockEnabled =
        prefs.getBool(PreferencesService.keyAppLockEnabled, fallback: false);
    c._appLockAuthMode =
        prefs.getString(PreferencesService.keyAppLockAuthMode, fallback: appLockAuthAny) ==
                appLockAuthBiometric
            ? appLockAuthBiometric
            : appLockAuthAny;
    c._appLocked = c._appLockEnabled;
    c._ttsVoice =
        prefs.getString(PreferencesService.keyTtsVoice, fallback: 'stella') == 'tide'
            ? 'tide'
            : 'stella';
    c._featureTitle = prefs.getBool(PreferencesService.keyFeatureTitle, fallback: true);
    c._featureFiles = prefs.getBool(PreferencesService.keyFeatureFiles, fallback: true);
    c._featureAsr = prefs.getBool(PreferencesService.keyFeatureAsr, fallback: true);
    c._featureTts = prefs.getBool(PreferencesService.keyFeatureTts, fallback: true);
    c._featureImage = prefs.getBool(PreferencesService.keyFeatureImage, fallback: true);
    c._featureSafety = prefs.getBool(PreferencesService.keyFeatureSafety, fallback: false);
    c._featureReadUrl = prefs.getBool(PreferencesService.keyFeatureReadUrl, fallback: true);
    c._webSearchProvider =
        prefs.getString(PreferencesService.keyWebSearchProvider,
            fallback: webSearchProviderDeepseek) ==
                webSearchProviderBaizhi
            ? webSearchProviderBaizhi
            : webSearchProviderDeepseek;
    c._userLocation = prefs.getString(PreferencesService.keyUserLocation);
    return c;
  }

  static String _validAppearance(String value) {
    if (value == 'light' || value == 'dark' || value == 'system') {
      return value;
    }
    return 'system';
  }

  Future<void> setSkin(String id) async {
    _skinId = skinById(id).id;
    notifyListeners();
    await _prefs.setString(PreferencesService.keySkin, _skinId);
  }

  Future<void> setAppearance(String value) async {
    _appearance = _validAppearance(value);
    notifyListeners();
    await _prefs.setString(PreferencesService.keyAppearance, _appearance);
  }

  Future<void> setFontSizeLevel(int level) async {
    _fontLevel = level.clamp(1, 7);
    notifyListeners();
    await _prefs.setInt(PreferencesService.keyFontSizeLevel, _fontLevel);
  }

  Future<void> setAutoCollapseThinking(bool enabled) async {
    _autoCollapseThinking = enabled;
    notifyListeners();
    await _prefs.setBool(PreferencesService.keyAutoCollapseThinking, enabled);
  }

  Future<void> setLanguage(String language) async {
    _language = language == 'en-US' ? 'en-US' : 'zh-CN';
    notifyListeners();
    await _prefs.setString(PreferencesService.keyAppLanguage, _language);
  }

  /// Business Rule: disabling the lock clears the current lock immediately;
  /// enabling it takes effect the next time the app leaves the foreground.
  Future<void> setAppLockEnabled(bool enabled) async {
    _appLockEnabled = enabled;
    if (!enabled) {
      _appLocked = false;
    }
    notifyListeners();
    await _prefs.setBool(PreferencesService.keyAppLockEnabled, enabled);
  }

  /// 解锁方式：只影响下次验证；关闭应用锁不清空，重新开启时沿用用户选择。
  Future<void> setAppLockAuthMode(String mode) async {
    _appLockAuthMode =
        mode == appLockAuthBiometric ? appLockAuthBiometric : appLockAuthAny;
    notifyListeners();
    await _prefs.setString(
      PreferencesService.keyAppLockAuthMode,
      _appLockAuthMode,
    );
  }

  void lock() {
    if (!_appLockEnabled || _appLocked) {
      return;
    }
    _appLocked = true;
    notifyListeners();
  }

  void unlock() {
    if (!_appLocked) {
      return;
    }
    _appLocked = false;
    notifyListeners();
  }

  Future<String> readProviderKey(String providerId) =>
      _keyStore.read(KeyStore.providerKey(providerId));

  Future<void> writeProviderKey(String providerId, String key) =>
      _keyStore.write(KeyStore.providerKey(providerId), key);

  Future<void> deleteProviderKey(String providerId) =>
      _keyStore.delete(KeyStore.providerKey(providerId));

  /// 功能开关：先 notify 再落盘（与鸿蒙端「即时生效」一致）。
  Future<void> setFeatureBool(String prefKey, bool value) async {
    switch (prefKey) {
      case PreferencesService.keyFeatureTitle:
        _featureTitle = value;
        break;
      case PreferencesService.keyFeatureFiles:
        _featureFiles = value;
        break;
      case PreferencesService.keyFeatureAsr:
        _featureAsr = value;
        break;
      case PreferencesService.keyFeatureTts:
        _featureTts = value;
        break;
      case PreferencesService.keyFeatureImage:
        _featureImage = value;
        break;
      case PreferencesService.keyFeatureSafety:
        _featureSafety = value;
        break;
      case PreferencesService.keyFeatureReadUrl:
        _featureReadUrl = value;
        break;
      default:
        return;
    }
    notifyListeners();
    await _prefs.setBool(prefKey, value);
  }

  Future<void> setWebSearchProvider(String provider) async {
    _webSearchProvider = provider == webSearchProviderBaizhi
        ? webSearchProviderBaizhi
        : webSearchProviderDeepseek;
    notifyListeners();
    await _prefs.setString(
      PreferencesService.keyWebSearchProvider,
      _webSearchProvider,
    );
  }

  Future<String> readBaizhiWebKey() => _keyStore.read(KeyStore.baizhiWeb);

  Future<void> writeBaizhiWebKey(String key) =>
      _keyStore.write(KeyStore.baizhiWeb, key);

  Future<String> readBaizhiImageKey() => _keyStore.read(KeyStore.baizhiImage);

  Future<void> writeBaizhiImageKey(String key) =>
      _keyStore.write(KeyStore.baizhiImage, key);

  Future<void> setTtsVoice(String voice) async {
    _ttsVoice = voice == 'tide' ? 'tide' : 'stella';
    notifyListeners();
    await _prefs.setString(PreferencesService.keyTtsVoice, _ttsVoice);
  }

  /// 所在地：只用于 latest_reminder，允许留空；换行/超长在 sanitizeLocation 收口。
  Future<void> setUserLocation(String location) async {
    _userLocation = sanitizeLocation(location);
    notifyListeners();
    await _prefs.setString(PreferencesService.keyUserLocation, _userLocation);
  }
}