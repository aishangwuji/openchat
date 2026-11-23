/*
 * SettingsService.ets
 *
 * 全局设置项管理服务 —— 外观模式、字体大小缩放、思考折叠等个性化配置。
 * 遵循 ArkTS 严格模式规范：无 any/unknown，无解构，强类型定义。
 */

import { preferences } from '@kit.ArkData';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { sanitizeLocation } from '../models/ChatModels';

const DOMAIN = 0x0000;
const TAG = 'SettingsService';
const PREFS_NAME = 'balance_prefs';

// 偏好键常量
export const KEY_APP_APPEARANCE = 'app_appearance'; // 'system' | 'light' | 'dark'
export const KEY_FONT_SIZE_LEVEL = 'app_font_size_level'; // 1 ~ 7，默认 3
export const KEY_AUTO_COLLAPSE_THINKING = 'auto_collapse_thinking'; // boolean，默认 true
/** 朗读音色：stella（海星，女声，默认）| tide（暗潮，男声）。 */
export const KEY_TTS_VOICE = 'tts_voice_id'; // string
/** 百智云生图 API Key（只落本机 Preferences，不进日志）。 */
export const KEY_BAIZHI_IMAGE = 'key_baizhi_image'; // string
/** 百智云联网搜索 API Key（与生图 Key 分开，可分别授权）。 */
export const KEY_BAIZHI_WEB = 'key_baizhi_web'; // string
/**
 * 百智云各模块 Key 是否已配置（AppStorage，boolean）。
 * Business Rule: 百智云的 Key 按功能模块签发、互不通用，所以状态也按模块分开；
 *   聊天页用 @StorageProp 订阅，保存/清除后立即生效，不必重启应用。
 */
export const KEY_BAIZHI_IMAGE_READY = 'baizhi_image_configured'; // boolean
export const KEY_BAIZHI_WEB_READY = 'baizhi_web_configured'; // boolean
/** 联网搜索能力来源：'deepseek'（服务端内置工具）| 'baizhi'（百智云 OpenAPI）。 */
export const KEY_WEB_SEARCH_PROVIDER = 'web_search_provider'; // string
export const WEB_SEARCH_PROVIDER_DEEPSEEK = 'deepseek';
export const WEB_SEARCH_PROVIDER_BAIZHI = 'baizhi';

/** 功能开关（设置 > 工具）：默认值与键名集中在这里，避免散落魔法字符串。 */
export const KEY_FEATURE_TITLE = 'feature_auto_title'; // boolean，默认 true
export const KEY_FEATURE_FILES = 'feature_files'; // boolean，默认 true
export const KEY_FEATURE_ASR = 'feature_asr'; // boolean，默认 true
export const KEY_FEATURE_TTS = 'feature_tts'; // boolean，默认 true
export const KEY_FEATURE_IMAGE = 'feature_image'; // boolean，默认 true
export const KEY_FEATURE_SAFETY = 'feature_safety'; // boolean，默认 false
export const KEY_FEATURE_READ_URL = 'feature_read_url'; // boolean，默认 true
/** 用户所在地（注入 latest_reminder，可留空）。 */
export const KEY_USER_LOCATION = 'user_location'; // string，默认 ''
export const DEFAULT_TTS_VOICE = 'stella';
/**
 * 解析后的实际深色态（system 时跟随系统），供非资源侧（Markdown 主题）读取。
 * Business Rule: 资源颜色由 setColorMode 自动切换，但 Markdown 库主题需显式布尔，
 *   故此处统一落一个已解析值，避免 system+系统深色时正文配色与背景不一致（隐形）。
 */
export const KEY_APP_DARK = 'app_dark'; // boolean
/** 应用锁开关（离开应用后需验证锁屏密码/指纹/人脸）。 */
export const KEY_APP_LOCK_ENABLED = 'app_lock_enabled'; // boolean
/** 当前应用是否处于锁定态；由 EntryAbility 切后台时置 true，认证通过后置 false。 */
export const KEY_APP_LOCKED = 'app_locked'; // boolean

// 7 档字体缩放系数，第 3 档为标准大小 (1.0)
export const FONT_SCALE_LEVELS: number[] = [0.85, 0.92, 1.0, 1.08, 1.16, 1.25, 1.35];

export type AppearanceMode = 'system' | 'light' | 'dark';

export class SettingsService {
  private static prefsInstance: preferences.Preferences | undefined = undefined;

  /**
   * 初始化设置，从 Preferences 读取持久化设置并同步到 AppStorage
   */
  public static async init(context: common.UIAbilityContext): Promise<void> {
    try {
      SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });

      // 1. 外观模式
      const appModeVal: preferences.ValueType = await SettingsService.prefsInstance.get(KEY_APP_APPEARANCE, 'system');
      let appearance: AppearanceMode = 'system';
      if (typeof appModeVal === 'string' && (appModeVal === 'system' || appModeVal === 'light' || appModeVal === 'dark')) {
        appearance = appModeVal as AppearanceMode;
      }
      AppStorage.setOrCreate<string>(KEY_APP_APPEARANCE, appearance);
      SettingsService.applyColorMode(context, appearance);
      SettingsService.storeResolvedDark(context, appearance);

      // 2. 字体大小档位 (1 ~ 7，第 3 档为标准)
      const fontLevelVal: preferences.ValueType = await SettingsService.prefsInstance.get(KEY_FONT_SIZE_LEVEL, 3);
      let fontLevel: number = 3;
      if (typeof fontLevelVal === 'number' && fontLevelVal >= 1 && fontLevelVal <= 7) {
        fontLevel = Math.round(fontLevelVal);
      }
      AppStorage.setOrCreate<number>(KEY_FONT_SIZE_LEVEL, fontLevel);
      const fontScale: number = SettingsService.getScaleByLevel(fontLevel);
      AppStorage.setOrCreate<number>('app_font_scale', fontScale);

      // 3. 思考内容自动折叠 (默认 true)
      const collapseVal: preferences.ValueType = await SettingsService.prefsInstance.get(KEY_AUTO_COLLAPSE_THINKING, true);
      let autoCollapse: boolean = true;
      if (typeof collapseVal === 'boolean') {
        autoCollapse = collapseVal;
      }
      AppStorage.setOrCreate<boolean>(KEY_AUTO_COLLAPSE_THINKING, autoCollapse);

      // 3.1 朗读音色 (默认 stella)
      const voiceVal: preferences.ValueType = await SettingsService.prefsInstance.get(KEY_TTS_VOICE, DEFAULT_TTS_VOICE);
      const ttsVoice: string = typeof voiceVal === 'string' && (voiceVal === 'stella' || voiceVal === 'tide') ?
        voiceVal as string : DEFAULT_TTS_VOICE;
      AppStorage.setOrCreate<string>(KEY_TTS_VOICE, ttsVoice);

      // 4.5 工具开关与服务商：全部进 AppStorage，页面用 @StorageProp 直接响应。
      await SettingsService.loadToolsConfig();
      // 4.6 百智云各模块 Key 的「已配置」状态：聊天页据此决定是否声明生图工具。
      await SettingsService.loadBaizhiKeyState();

      // 4. 应用锁：仅在首次初始化时决定是否直接锁定，避免页面再次 init 时把已解锁状态重置。
      const lockVal: preferences.ValueType = await SettingsService.prefsInstance.get(KEY_APP_LOCK_ENABLED, false);
      let appLockEnabled: boolean = false;
      if (typeof lockVal === 'boolean') {
        appLockEnabled = lockVal;
      }
      AppStorage.setOrCreate<boolean>(KEY_APP_LOCK_ENABLED, appLockEnabled);
      const existingLocked: boolean | undefined = AppStorage.get<boolean>(KEY_APP_LOCKED);
      if (appLockEnabled && existingLocked === undefined) {
        AppStorage.setOrCreate<boolean>(KEY_APP_LOCKED, true);
      } else if (!appLockEnabled) {
        AppStorage.setOrCreate<boolean>(KEY_APP_LOCKED, false);
      }

      hilog.info(DOMAIN, TAG, 'SettingsService initialized successfully: appearance=%{public}s, fontLevel=%{public}d, autoCollapse=%{public}s, appLock=%{public}s',
        appearance, fontLevel, String(autoCollapse), String(appLockEnabled));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'SettingsService init failed: %{public}s', String(err));
    }
  }

  /**
   * 根据档位获取对应文字倍率
   */
  public static getScaleByLevel(level: number): number {
    const idx: number = Math.max(1, Math.min(7, level)) - 1;
    return FONT_SCALE_LEVELS[idx];
  }

  /**
   * 应用系统/浅色/深色外观
   */
  public static applyColorMode(context: common.UIAbilityContext, mode: AppearanceMode): void {
    try {
      let colorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      if (mode === 'light') {
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      } else if (mode === 'dark') {
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
      context.getApplicationContext().setColorMode(colorMode);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'applyColorMode failed: %{public}s', String(err));
    }
  }

  /** 解析并落存实际深色态，供 Markdown 等非资源侧读取。 */
  private static storeResolvedDark(context: common.UIAbilityContext, mode: AppearanceMode): void {
    AppStorage.setOrCreate<boolean>(KEY_APP_DARK, SettingsService.resolveDark(context, mode));
  }

  /**
   * 解析实际深色态：显式 light/dark 直接决定；system 读系统配置。
   * Reason: setColorMode 只切换资源解析，Markdown 库主题需显式布尔，故统一收口于此。
   */
  public static resolveDark(context: common.UIAbilityContext, mode: AppearanceMode): boolean {
    if (mode === 'dark') {
      return true;
    }
    if (mode === 'light') {
      return false;
    }
    try {
      return context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (err) {
      return false;
    }
  }

  /**
   * 设置外观模式并持久化
   */
  public static async setAppearance(context: common.UIAbilityContext, mode: AppearanceMode): Promise<void> {
    AppStorage.setOrCreate<string>(KEY_APP_APPEARANCE, mode);
    SettingsService.applyColorMode(context, mode);
    SettingsService.storeResolvedDark(context, mode);

    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(KEY_APP_APPEARANCE, mode);
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAppearance save failed: %{public}s', String(err));
    }
  }

  /**
   * 设置字体大小档位 (1 ~ 7)
   */
  public static async setFontSizeLevel(context: common.UIAbilityContext, level: number): Promise<void> {
    const validLevel: number = Math.max(1, Math.min(7, level));
    AppStorage.setOrCreate<number>(KEY_FONT_SIZE_LEVEL, validLevel);
    AppStorage.setOrCreate<number>('app_font_scale', SettingsService.getScaleByLevel(validLevel));

    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(KEY_FONT_SIZE_LEVEL, validLevel);
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setFontSizeLevel save failed: %{public}s', String(err));
    }
  }

  /**
   * 设置应用锁开关并持久化。
   * Business Rule: 关闭时立即清除当前锁定态；开启后不立即锁定，待应用离开后台时生效。
   */
  public static async setAppLockEnabled(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
    AppStorage.setOrCreate<boolean>(KEY_APP_LOCK_ENABLED, enabled);
    if (!enabled) {
      AppStorage.setOrCreate<boolean>(KEY_APP_LOCKED, false);
    }

    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(KEY_APP_LOCK_ENABLED, enabled);
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAppLockEnabled save failed: %{public}s', String(err));
    }
  }

  /**
   * 设置思考内容自动折叠
   */
  public static async setAutoCollapseThinking(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
    AppStorage.setOrCreate<boolean>(KEY_AUTO_COLLAPSE_THINKING, enabled);

    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(KEY_AUTO_COLLAPSE_THINKING, enabled);
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAutoCollapseThinking save failed: %{public}s', String(err));
    }
  }

  /**
   * 设置朗读音色（仅 DeepSeek TTS 的两种音色：stella / tide）。
   * Business Rule: 非法值一律回落 stella，避免把脏值发给服务端导致 400。
   */
  public static async setTtsVoice(context: common.UIAbilityContext, voiceId: string): Promise<void> {
    const voice: string = voiceId === 'tide' ? 'tide' : 'stella';
    AppStorage.setOrCreate<string>(KEY_TTS_VOICE, voice);

    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(KEY_TTS_VOICE, voice);
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setTtsVoice save failed: %{public}s', String(err));
    }
  }

  /** 读取朗读音色；未初始化/非法值回落默认 stella。 */
  public static async getTtsVoice(context: common.UIAbilityContext): Promise<string> {
    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      const val: preferences.ValueType = await SettingsService.prefsInstance.get(KEY_TTS_VOICE, DEFAULT_TTS_VOICE);
      if (typeof val === 'string' && (val === 'stella' || val === 'tide')) {
        return val as string;
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getTtsVoice failed: %{public}s', String(err));
    }
    return DEFAULT_TTS_VOICE;
  }

  /**
   * 对话服务商 Key：与资产监控共用 `key_<providerId>`，不另存第二份。
   * Business Rule: 两处入口写同一个偏好键，避免「设置页改了、资产页还是旧 Key」的双源问题。
   */
  public static async getProviderKey(context: common.UIAbilityContext, providerId: string): Promise<string> {
    if (providerId.length === 0) {
      return '';
    }
    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      const val: preferences.ValueType = await SettingsService.prefsInstance.get(`key_${providerId}`, '');
      return typeof val === 'string' ? val as string : '';
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getProviderKey failed: %{public}s', String(err));
      return '';
    }
  }

  public static async setProviderKey(
    context: common.UIAbilityContext,
    providerId: string,
    apiKey: string
  ): Promise<void> {
    if (providerId.length === 0) {
      return;
    }
    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(`key_${providerId}`, apiKey.trim());
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setProviderKey save failed: %{public}s', String(err));
    }
  }

  /** 百智云生图 Key（与对话服务商 Key 分开存，避免混用）。 */
  public static async getImageKey(context: common.UIAbilityContext): Promise<string> {
    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      const val: preferences.ValueType = await SettingsService.prefsInstance.get(KEY_BAIZHI_IMAGE, '');
      return typeof val === 'string' ? val as string : '';
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getImageKey failed: %{public}s', String(err));
      return '';
    }
  }

  /** 保存百智云 Key；传空字符串表示清除。 */
  public static async setImageKey(context: common.UIAbilityContext, apiKey: string): Promise<void> {
    const trimmed: string = apiKey.trim();
    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(KEY_BAIZHI_IMAGE, trimmed);
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setImageKey save failed: %{public}s', String(err));
      return;
    }
    // 落盘成功才翻转状态，聊天页订阅此值，保存即生效（无需重启）。
    AppStorage.setOrCreate<boolean>(KEY_BAIZHI_IMAGE_READY, trimmed.length > 0);
  }
  /** 读取工具开关与服务商到 AppStorage（init 与设置页刷新共用）。 */
  public static async loadToolsConfig(): Promise<void> {
    await SettingsService.loadFeature(KEY_FEATURE_TITLE, true);
    await SettingsService.loadFeature(KEY_FEATURE_FILES, true);
    await SettingsService.loadFeature(KEY_FEATURE_ASR, true);
    await SettingsService.loadFeature(KEY_FEATURE_TTS, true);
    await SettingsService.loadFeature(KEY_FEATURE_IMAGE, true);
    await SettingsService.loadFeature(KEY_FEATURE_SAFETY, false);
    await SettingsService.loadFeature(KEY_FEATURE_READ_URL, true);
    const prefs: preferences.Preferences | undefined = SettingsService.prefsInstance;
    if (prefs === undefined) {
      return;
    }
    const provVal: preferences.ValueType = await prefs.get(KEY_WEB_SEARCH_PROVIDER, WEB_SEARCH_PROVIDER_DEEPSEEK);
    const provider: string = typeof provVal === 'string' && (provVal as string) === WEB_SEARCH_PROVIDER_BAIZHI
      ? WEB_SEARCH_PROVIDER_BAIZHI : WEB_SEARCH_PROVIDER_DEEPSEEK;
    AppStorage.setOrCreate<string>(KEY_WEB_SEARCH_PROVIDER, provider);
    const locVal: preferences.ValueType = await prefs.get(KEY_USER_LOCATION, '');
    const location: string = typeof locVal === 'string' ? sanitizeLocation(locVal as string) : '';
    AppStorage.setOrCreate<string>(KEY_USER_LOCATION, location);
  }

  /** 用户所在地：注入 latest_reminder，可留空；写盘后同步 AppStorage。 */
  public static async setUserLocation(context: common.UIAbilityContext, raw: string): Promise<void> {
    const location: string = sanitizeLocation(raw);
    AppStorage.setOrCreate<string>(KEY_USER_LOCATION, location);
    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(KEY_USER_LOCATION, location);
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setUserLocation save failed: %{public}s', String(err));
    }
  }

  private static async loadFeature(key: string, fallback: boolean): Promise<void> {
    const prefs: preferences.Preferences | undefined = SettingsService.prefsInstance;
    if (prefs === undefined) {
      return;
    }
    const val: preferences.ValueType = await prefs.get(key, fallback);
    const enabled: boolean = typeof val === 'boolean' ? val as boolean : fallback;
    AppStorage.setOrCreate<boolean>(key, enabled);
  }

  /** 写功能开关：先更新 AppStorage 让界面即时生效，再落盘。 */
  public static async setFeature(context: common.UIAbilityContext, key: string, enabled: boolean): Promise<void> {
    AppStorage.setOrCreate<boolean>(key, enabled);
    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(key, enabled);
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setFeature save failed: %{public}s', String(err));
    }
  }

  /** 联网搜索来源（deepseek 内置 / baizhi OpenAPI）。 */
  public static async setWebSearchProvider(context: common.UIAbilityContext, provider: string): Promise<void> {
    const valid: string = provider === WEB_SEARCH_PROVIDER_BAIZHI
      ? WEB_SEARCH_PROVIDER_BAIZHI : WEB_SEARCH_PROVIDER_DEEPSEEK;
    AppStorage.setOrCreate<string>(KEY_WEB_SEARCH_PROVIDER, valid);
    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(KEY_WEB_SEARCH_PROVIDER, valid);
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setWebSearchProvider failed: %{public}s', String(err));
    }
  }

  /** 百智云联网搜索 Key（与生图 Key 分开）。 */
  public static async getBaizhiWebKey(context: common.UIAbilityContext): Promise<string> {
    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      const val: preferences.ValueType = await SettingsService.prefsInstance.get(KEY_BAIZHI_WEB, '');
      return typeof val === 'string' ? val as string : '';
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getBaizhiWebKey failed: %{public}s', String(err));
      return '';
    }
  }

  public static async setBaizhiWebKey(context: common.UIAbilityContext, apiKey: string): Promise<void> {
    const trimmed: string = apiKey.trim();
    try {
      if (SettingsService.prefsInstance === undefined) {
        SettingsService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await SettingsService.prefsInstance.put(KEY_BAIZHI_WEB, trimmed);
      await SettingsService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setBaizhiWebKey failed: %{public}s', String(err));
      return;
    }
    AppStorage.setOrCreate<boolean>(KEY_BAIZHI_WEB_READY, trimmed.length > 0);
  }

  /** 读百智云各模块 Key 的配置状态进 AppStorage（只看有无，不回显明文）。 */
  public static async loadBaizhiKeyState(): Promise<void> {
    const prefs: preferences.Preferences | undefined = SettingsService.prefsInstance;
    if (prefs === undefined) {
      return;
    }
    try {
      const imgVal: preferences.ValueType = await prefs.get(KEY_BAIZHI_IMAGE, '');
      const webVal: preferences.ValueType = await prefs.get(KEY_BAIZHI_WEB, '');
      const imgReady: boolean = typeof imgVal === 'string' && (imgVal as string).trim().length > 0;
      const webReady: boolean = typeof webVal === 'string' && (webVal as string).trim().length > 0;
      AppStorage.setOrCreate<boolean>(KEY_BAIZHI_IMAGE_READY, imgReady);
      AppStorage.setOrCreate<boolean>(KEY_BAIZHI_WEB_READY, webReady);
      // 只打印「有没有配」，不打印 Key 本身。
      hilog.info(DOMAIN, TAG, 'baizhi key state: imageReady=%{public}s webReady=%{public}s',
        String(imgReady), String(webReady));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'loadBaizhiKeyState failed: %{public}s', String(err));
    }
  }
}