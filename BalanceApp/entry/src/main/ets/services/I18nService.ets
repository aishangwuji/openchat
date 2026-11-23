/*
 * I18nService.ets
 *
 * 应用国际化多语言服务 —— 支持中文（简体）与英文（English）。
 * 提供基于 AppStorage 的全局响应式语言切换与 Preferences 持久化存储。
 *
 * 遵循 ArkTS 严格模式规范：禁止解构、强类型定义、无 any/unknown。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { i18n } from '@kit.LocalizationKit';

const DOMAIN = 0x0000;
const TAG = 'I18nService';
const PREFS_NAME = 'balance_prefs';
const KEY_APP_LANGUAGE = 'app_language';

export type AppLanguage = 'zh-CN' | 'en-US';

export interface LanguageItem {
  code: AppLanguage;
  name: string;
  nativeName: string;
}

export const SUPPORTED_LANGUAGES: LanguageItem[] = [
  { code: 'zh-CN', name: '中文（简体）', nativeName: '中文（简体中文）' },
  { code: 'en-US', name: 'English', nativeName: 'English' }
];

const DICTIONARY: Record<AppLanguage, Record<string, string>> = {
  'zh-CN': {
    'settings_title': '设置',
    'settings_section_app': '应用',
    'settings_language': '语言',
    'settings_language_current': '中文（简体中文）',
    'settings_appearance': '外观',
    'settings_appearance_system': '系统',
    'settings_appearance_light': '浅色',
    'settings_appearance_dark': '深色',
    'settings_appearance_select': '选择外观模式',
    'settings_skin': '主题风格',
    'settings_skin_select': '选择主题风格',
    'settings_font_size': '字体大小',
    'settings_font_size_title': '设置字体大小',
    'settings_font_size_preview_title': '预览效果',
    'settings_font_size_preview_sample': '这是一段用于预览字体大小的文字样例。拖动下方滑块调整整体界面字号。',
    'settings_font_size_standard': '标准',
    'settings_personalize': '个性化',
    'settings_auto_collapse_thinking': '思考内容自动折叠',
    'settings_auto_collapse_thinking_desc': '开启后，思考结束后将自动折叠思考内容。',
    'settings_section_voice': '语音',
    'settings_tts_voice': '朗读音色',
    'settings_voice_title': '选择朗读音色',
    'settings_voice_hint': '朗读回答时使用的声音；由 DeepSeek 语音合成提供。',
    'settings_voice_stella': '海星（女声）',
    'settings_voice_stella_desc': '默认音色，语气自然平稳',
    'settings_voice_tide': '暗潮（男声）',
    'settings_voice_tide_desc': '偏低沉的男声',
    'settings_section_security': '安全',
    'settings_app_lock': '应用锁',
    'settings_app_lock_title': '应用锁',
    'settings_app_lock_desc': '开启后，离开应用再进入时需验证锁屏密码、指纹或人脸识别。',
    'settings_app_lock_on': '已开启',
    'settings_app_lock_off': '未开启',
    'settings_section_data': '数据',
    'settings_assets': '资产监控',
    'settings_assets_desc': '查看各服务商余额',
    'settings_channel': '渠道',
    'settings_provider': '服务商',
    'settings_section_tools': '工具',
    'settings_web_provider': '联网搜索',
    'settings_web_provider_desc': '选择联网搜索由谁提供：DeepSeek 内置工具免费但仅 DeepSeek 可用；百智云 OpenAPI 支持多服务商，需要单独的 Key。',
    'settings_web_provider_deepseek': 'DeepSeek 内置',
    'settings_web_provider_deepseek_desc': '服务端直接联网，来源随回答返回，不额外配置。',
    'settings_web_provider_baizhi': '百智云',
    'settings_web_provider_baizhi_desc': '独立搜索服务，每次搜索按积分计费；需填百智云「联网搜索」Key。',
    'settings_web_key': '百智云 · 联网搜索 Key',
    'settings_web_key_desc': '只对「联网搜索」模块生效。百智云按模块签发 Key，与生图 Key 互不通用；Key 只存本机。',
    'settings_web_key_placeholder': '粘贴百智云「联网搜索」Key',
    'settings_feature_title': '自动生成会话标题',
    'settings_feature_files': '文件与图片解析',
    'settings_feature_read_url': '阅读链接',
    'settings_feature_asr': '语音输入',
    'settings_feature_tts': '朗读回答',
    'settings_feature_image': '图片生成',
    'settings_feature_safety': '模型内容安全',    'settings_section_image': '图像生成',
    'settings_image_key': '百智云 · 生图 Key',
    'settings_image_key_on': '已配置',
    'settings_image_key_off': '未配置',
    'settings_image_key_desc': '只对「生图」模块生效，保存后立即生效。百智云按模块签发 Key，与联网搜索 Key 互不通用。',
    'settings_image_key_placeholder': '粘贴百智云「生图」Key',
    'settings_image_save': '保存',
    'settings_image_clear': '清除',    'settings_section_about': '关于',
    'settings_check_update': '检查更新',
    'settings_checking': '检查中…',
    'settings_up_to_date': '已是最新版本',
    'settings_check_failed': '暂时无法检查更新，请稍后再试',
    'settings_new_version_title': '发现新版本',
    'settings_download': '去下载',
    'settings_later': '以后再说',
    'settings_project_page': '开源主页',
    'settings_version': '版本 1.0.0',
    'settings_select_language': '选择语言',
    'chat_greeting_morning': '早上好，今天想做点什么？',
    'chat_greeting_afternoon': '下午好，今天想做点什么？',
    'chat_greeting_evening': '晚上好，今天想做点什么？',
    'chat_greeting_night': '夜深了，想聊点什么？',
    'common_cancel': '取消',
    'common_confirm': '确定',
    'common_not_implemented': '该功能暂未实现',
  },
  'en-US': {
    'settings_title': 'Settings',
    'settings_section_app': 'Application',
    'settings_language': 'Language',
    'settings_language_current': 'English',
    'settings_appearance': 'Appearance',
    'settings_appearance_system': 'System',
    'settings_appearance_light': 'Light',
    'settings_appearance_dark': 'Dark',
    'settings_appearance_select': 'Select Appearance',
    'settings_skin': 'Theme',
    'settings_skin_select': 'Select a theme',
    'settings_font_size': 'Font Size',
    'settings_font_size_title': 'Font Size',
    'settings_font_size_preview_title': 'Preview',
    'settings_font_size_preview_sample': 'This is a sample text for previewing font size. Drag the slider below to adjust text size across the app.',
    'settings_font_size_standard': 'Standard',
    'settings_personalize': 'Personalization',
    'settings_auto_collapse_thinking': 'Auto-collapse Thinking Process',
    'settings_auto_collapse_thinking_desc': 'When enabled, the thinking process will collapse automatically after generation ends.',
    'settings_section_voice': 'Voice',
    'settings_tts_voice': 'Read-aloud Voice',
    'settings_voice_title': 'Choose a Voice',
    'settings_voice_hint': 'Voice used when reading answers aloud, powered by DeepSeek TTS.',
    'settings_voice_stella': 'Stella (female)',
    'settings_voice_stella_desc': 'Default voice, natural and steady',
    'settings_voice_tide': 'Tide (male)',
    'settings_voice_tide_desc': 'A deeper male voice',
    'settings_section_security': 'Security',
    'settings_app_lock': 'App Lock',
    'settings_app_lock_title': 'App Lock',
    'settings_app_lock_desc': 'When enabled, entering the app after leaving requires your lock-screen password, fingerprint, or face.',
    'settings_app_lock_on': 'On',
    'settings_app_lock_off': 'Off',
    'settings_section_data': 'Data',
    'settings_assets': 'Assets & Balance',
    'settings_assets_desc': 'View provider balances',
    'settings_channel': 'Channel',
    'settings_provider': 'Provider',
    'settings_section_tools': 'Tools',
    'settings_web_provider': 'Web search',
    'settings_web_provider_desc': 'Choose who provides web search: DeepSeek built-in (free, DeepSeek only) or Baizhi OpenAPI (any provider, separate key).',
    'settings_web_provider_deepseek': 'DeepSeek built-in',
    'settings_web_provider_deepseek_desc': 'Server-side search; sources come back with the answer. No extra setup.',
    'settings_web_provider_baizhi': 'Baizhi',
    'settings_web_provider_baizhi_desc': 'Independent search service, billed per search; requires the Baizhi web-search key.',
    'settings_web_key': 'Baizhi · Web search key',
    'settings_web_key_desc': 'Only works for web search. Baizhi issues keys per module, so it is not interchangeable with the image key. Stored locally.',
    'settings_web_key_placeholder': 'Paste the Baizhi web-search key',
    'settings_feature_title': 'Auto session titles',
    'settings_feature_files': 'File & image parsing',
    'settings_feature_read_url': 'Read links',
    'settings_feature_asr': 'Voice input',
    'settings_feature_tts': 'Read answers aloud',
    'settings_feature_image': 'Image generation',
    'settings_feature_safety': 'Model content safety',    'settings_section_image': 'Image generation',
    'settings_image_key': 'Baizhi · Image key',
    'settings_image_key_on': 'Configured',
    'settings_image_key_off': 'Not configured',
    'settings_image_key_desc': 'Only works for image generation, effective right after saving. Baizhi issues keys per module; the web-search key will not work here.',
    'settings_image_key_placeholder': 'Paste the Baizhi image key',
    'settings_image_save': 'Save',
    'settings_image_clear': 'Clear',    'settings_section_about': 'About',
    'settings_check_update': 'Check for updates',
    'settings_checking': 'Checking…',
    'settings_up_to_date': 'You are on the latest version',
    'settings_check_failed': 'Could not check for updates. Try again later.',
    'settings_new_version_title': 'New version available',
    'settings_download': 'Download',
    'settings_later': 'Later',
    'settings_project_page': 'Project page',
    'settings_version': 'Version 1.0.0',
    'settings_select_language': 'Select Language',
    'chat_greeting_morning': 'Good morning. What would you like to do today?',
    'chat_greeting_afternoon': 'Good afternoon. What would you like to do today?',
    'chat_greeting_evening': 'Good evening. What would you like to do today?',
    'chat_greeting_night': 'Still up? What is on your mind?',
    'common_cancel': 'Cancel',
    'common_confirm': 'Confirm',
    'common_not_implemented': 'Feature not implemented yet',
  }
};

export class I18nService {
  private static currentLang: AppLanguage = 'zh-CN';
  private static prefsInstance: preferences.Preferences | undefined = undefined;

  /**
   * 初始化语言服务，从 Preferences 读取持久化设置
   */
  public static async init(context: common.UIAbilityContext): Promise<void> {
    try {
      I18nService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      const val: preferences.ValueType = await I18nService.prefsInstance.get(KEY_APP_LANGUAGE, 'zh-CN');
      let lang: AppLanguage = 'zh-CN';
      if (typeof val === 'string' && (val === 'zh-CN' || val === 'en-US')) {
        lang = val as AppLanguage;
      }
      I18nService.currentLang = lang;
      AppStorage.setOrCreate<string>('app_language', lang);
      hilog.info(DOMAIN, TAG, 'I18nService initialized with language: %{public}s', lang);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'I18nService init failed: %{public}s', String(err));
    }
  }

  /**
   * 获取当前语言
   */
  public static getLanguage(): AppLanguage {
    return I18nService.currentLang;
  }

  /**
   * 切换语言并持久化
   */
  public static async setLanguage(context: common.UIAbilityContext, lang: AppLanguage): Promise<void> {
    I18nService.currentLang = lang;
    AppStorage.setOrCreate<string>('app_language', lang);

    try {
      if (I18nService.prefsInstance === undefined) {
        I18nService.prefsInstance = await preferences.getPreferences(context, { name: PREFS_NAME });
      }
      await I18nService.prefsInstance.put(KEY_APP_LANGUAGE, lang);
      await I18nService.prefsInstance.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save language failed: %{public}s', String(err));
    }

    // 尝试同步系统偏好语言
    try {
      if (lang === 'zh-CN') {
        i18n.System.setAppPreferredLanguage('zh-Hans');
      } else {
        i18n.System.setAppPreferredLanguage('en');
      }
    } catch (e) {
      // 某些真机权限可能不允许，静默忽略
    }
  }

  /**
   * 获取指定 key 的国际化文本
   */
  public static t(key: string, langOverride?: AppLanguage): string {
    const lang: AppLanguage = langOverride || I18nService.currentLang;
    const dict: Record<string, string> = DICTIONARY[lang] || DICTIONARY['zh-CN'];
    const val: string | undefined = dict[key];
    if (val !== undefined) {
      return val;
    }
    const fallback: string | undefined = DICTIONARY['zh-CN'][key];
    return fallback !== undefined ? fallback : key;
  }
}


