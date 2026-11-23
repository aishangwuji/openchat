import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_version.dart';
import '../../core/i18n/settings_strings.dart';
import '../../core/theme/app_skins.dart';
import '../../core/theme/app_colors.dart';
import '../../data/services/preferences_service.dart';
import '../../data/services/update_service.dart';
import '../../state/settings_controller.dart';
import 'assets_page.dart';


class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _pickWebProvider(
    BuildContext context,
    SettingsController settings,
    SettingsStrings s,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: Text(s.t('settings_web_provider_deepseek')),
              trailing: settings.webSearchProvider == webSearchProviderDeepseek
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                settings.setWebSearchProvider(webSearchProviderDeepseek);
              },
            ),
            ListTile(
              title: Text(s.t('settings_web_provider_baizhi')),
              trailing: settings.webSearchProvider == webSearchProviderBaizhi
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                settings.setWebSearchProvider(webSearchProviderBaizhi);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 百智云 Key 编辑：只写安全存储，不显示明文；留空 = 清除。
  Future<void> _editBaizhiKey(
    BuildContext context,
    SettingsController settings,
    SettingsStrings s,
    bool isImage,
  ) async {
    final TextEditingController input = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(
          isImage ? s.t('settings_image_key') : s.t('settings_web_key'),
        ),
        content: TextField(
          controller: input,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(hintText: 'API Key'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              if (isImage) {
                await settings.writeBaizhiImageKey('');
              } else {
                await settings.writeBaizhiWebKey('');
              }
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
              }
            },
            child: Text(s.t('settings_key_clear')),
          ),
          FilledButton(
            onPressed: () async {
              final String value = input.text.trim();
              if (isImage) {
                await settings.writeBaizhiImageKey(value);
              } else {
                await settings.writeBaizhiWebKey(value);
              }
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
              }
            },
            child: Text(s.t('settings_key_save')),
          ),
        ],
      ),
    );
  }
  /// 手动检查更新：Gitee 优先、GitHub 兜底；只提示不强制。
  Future<void> _pickTtsVoice(
    BuildContext context,
    SettingsController settings,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: const Text('Stella（默认）'),
              trailing: settings.ttsVoice == 'stella'
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                settings.setTtsVoice('stella');
              },
            ),
            ListTile(
              title: const Text('Tide'),
              trailing: settings.ttsVoice == 'tide'
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                settings.setTtsVoice('tide');
              },
            ),
          ],
        ),
      ),
    );
  }
  Future<void> _checkUpdate(BuildContext context) async {
    final UpdateInfo? info = await UpdateService.check();
    if (!context.mounted) {
      return;
    }
    if (info == null) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('检查更新'),
          content: Text('已是最新版本（v${UpdateService.currentVersion}）'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('好'),
            ),
          ],
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('发现新版本 v${info.version}'),
        content: SingleChildScrollView(
          child: Text(info.notes.isEmpty ? 'v${info.version}' : info.notes),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('以后再说'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              launchUrl(
                Uri.parse(info.downloadUrl),
                mode: LaunchMode.externalApplication,
              );
            },
            child: const Text('去下载'),
          ),
        ],
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final SettingsController settings = context.watch<SettingsController>();
    final SettingsStrings s = SettingsStrings(settings.language);
    return Scaffold(
      backgroundColor: c.pageBg,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _Header(title: s.t('settings_title')),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                children: <Widget>[
                  _SectionLabel(text: s.t('settings_section_app')),
                  _SettingsCard(
                    children: <Widget>[
                      _SettingsRow(
                        title: s.t('settings_language'),
                        subtitle: s.t('settings_language_current'),
                        onTap: () => _pickLanguage(context, settings, s),
                      ),
                      _SettingsRow(
                        title: s.t('settings_appearance'),
                        subtitle: _appearanceLabel(settings, s),
                        onTap: () =>
                            _pickAppearance(context, settings, s),
                      ),
                      _SettingsRow(
                        title: s.t('settings_skin'),
                        subtitle: _skinLabel(settings),
                        onTap: () => _pickSkin(context, settings, s),
                      ),
                      _SettingsRow(
                        title: s.t('settings_font_size'),
                        subtitle: _fontLabel(settings, s),
                        onTap: () => _pickFontSize(context, settings, s),
                      ),
                    ],
                  ),
                  _SectionLabel(text: s.t('settings_personalize')),
                  _SettingsCard(
                    children: <Widget>[
                      _SettingsRow(
                        title: s.t('settings_auto_collapse_thinking'),
                        subtitle: s.t('settings_auto_collapse_thinking_desc'),
                        trailing: Switch(
                          value: settings.autoCollapseThinking,
                          onChanged: settings.setAutoCollapseThinking,
                        ),
                      ),
                    ],
                  ),
                  _SectionLabel(text: s.t('settings_section_tools')),
                  _SettingsCard(
                    children: <Widget>[
                      _SettingsRow(
                        title: s.t('settings_web_provider'),
                        trailing: Text(
                          settings.webSearchProvider == webSearchProviderBaizhi
                              ? s.t('settings_web_provider_baizhi')
                              : s.t('settings_web_provider_deepseek'),
                          style: TextStyle(fontSize: 12, color: c.textMuted),
                        ),
                        onTap: () => _pickWebProvider(context, settings, s),
                      ),
                      _SettingsRow(
                        title: s.t('settings_web_key'),
                        trailing: Icon(Icons.key_rounded, size: 18, color: c.iconMuted),
                        onTap: () => _editBaizhiKey(context, settings, s, false),
                      ),
                      _SettingsRow(
                        title: s.t('settings_image_key'),
                        trailing: Icon(Icons.key_rounded, size: 18, color: c.iconMuted),
                        onTap: () => _editBaizhiKey(context, settings, s, true),
                      ),
                    ],
                  ),
                  _SettingsCard(
                    children: <Widget>[
                      _SwitchRow(
                        title: s.t('settings_feature_title'),
                        value: settings.featureTitle,
                        onChanged: (bool v) =>
                            settings.setFeatureBool(PreferencesService.keyFeatureTitle, v),
                      ),
                      _SwitchRow(
                        title: s.t('settings_feature_files'),
                        value: settings.featureFiles,
                        onChanged: (bool v) =>
                            settings.setFeatureBool(PreferencesService.keyFeatureFiles, v),
                      ),
                      _SwitchRow(
                        title: s.t('settings_feature_read_url'),
                        value: settings.featureReadUrl,
                        onChanged: (bool v) =>
                            settings.setFeatureBool(PreferencesService.keyFeatureReadUrl, v),
                      ),
                      _SwitchRow(
                        title: s.t('settings_feature_asr'),
                        value: settings.featureAsr,
                        onChanged: (bool v) =>
                            settings.setFeatureBool(PreferencesService.keyFeatureAsr, v),
                      ),
                      _SwitchRow(
                        title: s.t('settings_feature_tts'),
                        value: settings.featureTts,
                        onChanged: (bool v) =>
                            settings.setFeatureBool(PreferencesService.keyFeatureTts, v),
                      ),
                      _SwitchRow(
                        title: s.t('settings_feature_image'),
                        value: settings.featureImage,
                        onChanged: (bool v) =>
                            settings.setFeatureBool(PreferencesService.keyFeatureImage, v),
                      ),
                      _SwitchRow(
                        title: s.t('settings_feature_safety'),
                        value: settings.featureSafety,
                        onChanged: (bool v) =>
                            settings.setFeatureBool(PreferencesService.keyFeatureSafety, v),
                      ),
                    ],
                  ),                  _SettingsCard(
                    children: <Widget>[
                      _SettingsRow(
                        title: '朗读音色',
                        trailing: Text(
                          settings.ttsVoice == 'tide' ? 'Tide' : 'Stella',
                          style: TextStyle(fontSize: 12, color: c.textMuted),
                        ),
                        onTap: () => _pickTtsVoice(context, settings),
                      ),
                    ],
                  ),                  _SectionLabel(text: s.t('settings_section_security')),
                  _SettingsCard(
                    children: <Widget>[
                      _SettingsRow(
                        title: s.t('settings_app_lock'),
                        subtitle: s.t('settings_app_lock_desc'),
                        trailing: Switch(
                          value: settings.appLockEnabled,
                          onChanged: settings.setAppLockEnabled,
                        ),
                      ),
                    ],
                  ),
                  _SectionLabel(text: s.t('settings_section_data')),
                  _SettingsCard(
                    children: <Widget>[
                      _SettingsRow(
                        title: s.t('settings_assets'),
                        subtitle: s.t('settings_assets_desc'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AssetsPage(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  _SectionLabel(text: '关于'),
                  _SettingsCard(
                    children: <Widget>[
                      _SettingsRow(
                        title: '检查更新',
                        trailing: Text(
                          'v$appVersion',
                          style: TextStyle(fontSize: 12, color: c.textMuted),
                        ),
                        onTap: () => _checkUpdate(context),
                      ),
                      _SettingsRow(
                        title: '开源主页',
                        onTap: () => launchUrl(
                          Uri.parse('https://gitee.com/aishangwuji/openchat'),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      s.t('settings_version'),
                      style: TextStyle(fontSize: 12, color: c.textFaint),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _appearanceLabel(SettingsController settings, SettingsStrings s) {
    switch (settings.appearance) {
      case 'light':
        return s.t('settings_appearance_light');
      case 'dark':
        return s.t('settings_appearance_dark');
      default:
        return s.t('settings_appearance_system');
    }
  }

  String _skinLabel(SettingsController settings) {
    final AppSkin skin = settings.skin;
    return settings.language == 'en-US' ? skin.nameEn : skin.name;
  }

  Future<void> _pickSkin(
    BuildContext context,
    SettingsController settings,
    SettingsStrings s,
  ) async {
    final AppColors c = context.colors;
    final bool en = settings.language == 'en-US';
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: <Widget>[
                    Text(
                      s.t('settings_skin_select'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: c.textTitle,
                      ),
                    ),
                  ],
                ),
              ),
              for (final AppSkin skin in appSkins)
                ListTile(
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _swatch(skin.light.pageBg),
                      _swatch(skin.light.surface),
                      _swatch(skin.light.accent),
                    ],
                  ),
                  title: Text(
                    en ? skin.nameEn : skin.name,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: settings.skinId == skin.id
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: settings.skinId == skin.id
                          ? c.accent
                          : c.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    en ? skin.noteEn : skin.note,
                    style: TextStyle(fontSize: 11, color: c.textMuted),
                  ),
                  trailing: settings.skinId == skin.id
                      ? Icon(Icons.check_rounded, size: 20, color: c.accent)
                      : null,
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await settings.setSkin(skin.id);
                  },
                ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Widget _swatch(Color color) {
    return Container(
      width: 10,
      height: 28,
      margin: const EdgeInsets.only(right: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: const Color(0x22000000)),
      ),
    );
  }

  String _fontLabel(SettingsController settings, SettingsStrings s) {
    return settings.fontLevel == 3
        ? s.t('settings_font_size_standard')
        : '${s.t('settings_font_size')} ${settings.fontLevel}/7';
  }

  Future<void> _pickLanguage(
    BuildContext context,
    SettingsController settings,
    SettingsStrings s,
  ) async {
    final AppColors c = context.colors;
    final String? selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.surface,
      builder: (BuildContext context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  s.t('settings_select_language'),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: c.textTitle,
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  title: const Text('中文（简体中文）'),
                  trailing: settings.language == 'zh-CN'
                      ? Icon(Icons.check_rounded, color: c.accent)
                      : null,
                  onTap: () => Navigator.of(context).pop('zh-CN'),
                ),
                ListTile(
                  title: const Text('English'),
                  trailing: settings.language == 'en-US'
                      ? Icon(Icons.check_rounded, color: c.accent)
                      : null,
                  onTap: () => Navigator.of(context).pop('en-US'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null) {
      await settings.setLanguage(selected);
    }
  }

  Future<void> _pickAppearance(
    BuildContext context,
    SettingsController settings,
    SettingsStrings s,
  ) async {
    final AppColors c = context.colors;
    final String? selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.surface,
      builder: (BuildContext context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  s.t('settings_appearance_select'),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: c.textTitle,
                  ),
                ),
                const SizedBox(height: 8),
                ...<MapEntry<String, String>>[
                  MapEntry<String, String>(
                    'system',
                    s.t('settings_appearance_system'),
                  ),
                  MapEntry<String, String>(
                    'light',
                    s.t('settings_appearance_light'),
                  ),
                  MapEntry<String, String>(
                    'dark',
                    s.t('settings_appearance_dark'),
                  ),
                ].map(
                  (MapEntry<String, String> item) => ListTile(
                    title: Text(item.value),
                    trailing: settings.appearance == item.key
                        ? Icon(Icons.check_rounded, color: c.accent)
                        : null,
                    onTap: () => Navigator.of(context).pop(item.key),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null) {
      await settings.setAppearance(selected);
    }
  }

  Future<void> _pickFontSize(
    BuildContext context,
    SettingsController settings,
    SettingsStrings s,
  ) async {
    final AppColors c = context.colors;
    int level = settings.fontLevel;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            final double scale = fontScaleLevels[level - 1];
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      s.t('settings_font_size_title'),
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: c.textTitle,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      s.t('settings_font_size_preview_title'),
                      style: TextStyle(
                        fontSize: 12,
                        color: c.textMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: c.surfaceRow,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        s.t('settings_font_size_preview_sample'),
                        style: TextStyle(
                          fontSize: 14 * scale,
                          height: 1.6,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                    Slider(
                      value: level.toDouble(),
                      min: 1,
                      max: 7,
                      divisions: 6,
                      label: '$level',
                      onChanged: (double value) =>
                          setState(() => level = value.round()),
                      onChangeEnd: (double value) =>
                          settings.setFontSizeLevel(value.round()),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Text(
                          'A',
                          style: TextStyle(fontSize: 11, color: c.textMuted),
                        ),
                        Text(
                          'A',
                          style: TextStyle(fontSize: 20, color: c.textMuted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    await settings.setFontSizeLevel(level);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(21),
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(21),
              ),
              child: Text(
                '‹',
                style: TextStyle(
                  fontSize: 28,
                  height: 1,
                  color: c.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: c.textTitle,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 18, 6, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: c.textMuted,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.borderSoft),
      ),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < children.length; i++) ...<Widget>[
            children[i],
            if (i != children.length - 1)
              Divider(
                color: c.divider,
                height: 1,
                indent: 16,
                endIndent: 16,
              ),
          ],
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,  });

  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: c.textPrimary,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: c.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ?trailing,            if (onTap != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: c.iconMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return SwitchListTile.adaptive(
      title: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: c.textPrimary,
        ),
      ),
      value: value,
      onChanged: onChanged,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      activeThumbColor: c.accent,
    );
  }
}