const Map<String, Map<String, String>> _settingsDictionary =
    <String, Map<String, String>>{
  'zh-CN': <String, String>{
    'settings_section_tools': '工具',
    'settings_web_provider': '联网搜索',
    'settings_web_provider_deepseek': 'DeepSeek 内置',
    'settings_web_provider_baizhi': '百智云',
    'settings_web_key': '百智云搜索 Key',
    'settings_image_key': '百智云生图 Key',
    'settings_key_configured': '已配置',
    'settings_key_not_configured': '未配置',
    'settings_key_save': '保存',
    'settings_key_clear': '清除',
    'settings_feature_title': '自动生成会话标题',
    'settings_feature_files': '文件与图片解析',
    'settings_feature_read_url': '阅读链接',
    'settings_feature_asr': '语音输入',
    'settings_feature_tts': '朗读回答',
    'settings_feature_image': '图片生成',
    'settings_feature_safety': '模型内容安全',
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
    'settings_version': '版本 1.0.0',
    'settings_select_language': '选择语言',
    'common_cancel': '取消',
    'common_confirm': '确定',
    'common_not_implemented': '该功能暂未实现',
    'settings_key_missing': '未配置',
    'settings_go_assets': '去资产监控配置',
  },
  'en-US': <String, String>{
    'settings_section_tools': 'Tools',
    'settings_web_provider': 'Web search',
    'settings_web_provider_deepseek': 'DeepSeek built-in',
    'settings_web_provider_baizhi': 'Baizhi',
    'settings_web_key': 'Baizhi search key',
    'settings_image_key': 'Baizhi image key',
    'settings_key_configured': 'Configured',
    'settings_key_not_configured': 'Not configured',
    'settings_key_save': 'Save',
    'settings_key_clear': 'Clear',
    'settings_feature_title': 'Auto session titles',
    'settings_feature_files': 'File & image parsing',
    'settings_feature_read_url': 'Read links',
    'settings_feature_asr': 'Voice input',
    'settings_feature_tts': 'Read answers aloud',
    'settings_feature_image': 'Image generation',
    'settings_feature_safety': 'Model content safety',
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
    'settings_font_size_preview_sample':
        'This is a sample text for previewing font size. Drag the slider below to adjust text size across the app.',
    'settings_font_size_standard': 'Standard',
    'settings_personalize': 'Personalization',
    'settings_auto_collapse_thinking': 'Auto-collapse Thinking Process',
    'settings_auto_collapse_thinking_desc':
        'When enabled, the thinking process will collapse automatically after generation ends.',
    'settings_section_security': 'Security',
    'settings_app_lock': 'App Lock',
    'settings_app_lock_title': 'App Lock',
    'settings_app_lock_desc':
        'When enabled, entering the app after leaving requires your lock-screen password, fingerprint, or face.',
    'settings_app_lock_on': 'On',
    'settings_app_lock_off': 'Off',
    'settings_section_data': 'Data',
    'settings_assets': 'Assets & Balance',
    'settings_assets_desc': 'View provider balances',



















    'settings_channel': 'Channel',

    'settings_provider': 'Provider',
    'settings_version': 'Version 1.0.0',
    'settings_select_language': 'Select Language',
    'common_cancel': 'Cancel',
    'common_confirm': 'Confirm',
    'common_not_implemented': 'Feature not implemented yet',
    'settings_key_missing': 'Not configured',
    'settings_go_assets': 'Configure in Assets & Balance',
  },
};

class SettingsStrings {
  const SettingsStrings(this.language);

  final String language;

  String t(String key) {
    final Map<String, String> dict =
        _settingsDictionary[language] ?? _settingsDictionary['zh-CN']!;
    return dict[key] ??
        _settingsDictionary['zh-CN']![key] ??
        key;
  }
}
