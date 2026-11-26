import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_version.dart';
import '../../core/i18n/settings_strings.dart';
import '../../core/theme/app_skins.dart';
import '../../core/theme/app_colors.dart';
import '../../data/services/apk_update_service.dart';
import '../../data/services/preferences_service.dart';
import '../../data/services/update_service.dart';
import '../../state/settings_controller.dart';
import '../widgets/update_download_sheet.dart';
import '../widgets/update_install_host.dart';
import 'assets_page.dart';


class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// 所在地编辑：只影响 latest_reminder，留空 = 不告诉模型所在地。
  Future<void> _editUserLocation(
    BuildContext context,
    SettingsController settings,
    SettingsStrings s,
  ) async {
    final TextEditingController input =
        TextEditingController(text: settings.userLocation);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(s.t('settings_user_location')),
        content: TextField(
          controller: input,
          autocorrect: false,
          decoration: InputDecoration(
            hintText: 'Singapore',
            helperText: s.t('settings_user_location_desc'),
            helperMaxLines: 2,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.t('settings_key_clear')),
          ),
          FilledButton(
            onPressed: () {
              settings.setUserLocation(input.text);
              Navigator.of(ctx).pop();
            },
            child: Text(s.t('settings_key_save')),
          ),
        ],
      ),
    );
  }

  /// 应用锁解锁方式：只分「系统自选」与「仅生物识别」两档。
  /// Business Rule: local_auth 无法只指定面容或只指定指纹，具体用哪种由系统决定。
  Future<void> _pickAppLockAuthMode(
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  s.t('settings_app_lock_method_title'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: ctx.colors.textTitle,
                  ),
                ),
              ),
            ),
            ListTile(
              title: Text(s.t('settings_app_lock_method_any')),
              subtitle: Text(s.t('settings_app_lock_method_any_desc')),
              trailing: settings.appLockAuthMode == appLockAuthAny
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                settings.setAppLockAuthMode(appLockAuthAny);
              },
            ),
            ListTile(
              title: Text(s.t('settings_app_lock_method_biometric')),
              subtitle: Text(s.t('settings_app_lock_method_biometric_desc')),
              trailing: settings.appLockAuthMode == appLockAuthBiometric
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                settings.setAppLockAuthMode(appLockAuthBiometric);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// 朗读音色：文案与鸿蒙端 `settings_voice_*` 保持一致（海星 / 暗潮）。
  Future<void> _pickTtsVoice(
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  s.t('settings_voice_title'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: ctx.colors.textTitle,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  s.t('settings_voice_hint'),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: ctx.colors.textMuted,
                  ),
                ),
              ),
            ),
            ListTile(
              title: Text(s.t('settings_voice_stella')),
              subtitle: Text(s.t('settings_voice_stella_desc')),
              trailing: settings.ttsVoice == 'stella'
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                settings.setTtsVoice('stella');
              },
            ),
            ListTile(
              title: Text(s.t('settings_voice_tide')),
              subtitle: Text(s.t('settings_voice_tide_desc')),
              trailing: settings.ttsVoice == 'tide'
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                settings.setTtsVoice('tide');
              },
            ),
            const SizedBox(height: 12),
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
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('发现新版本 v${info.version}'),
        content: SingleChildScrollView(
          child: Text(info.notes.isEmpty ? 'v${info.version}' : info.notes),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('以后再说'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) {
      return;
    }
    await _startUpdate(context, info);
  }

  /// 应用内下载 APK 并拉起系统安装页；非 Android 或非直链仍回退浏览器。
  Future<void> _startUpdate(BuildContext context, UpdateInfo info) async {
    if (!ApkUpdateService.isSupported ||
        !ApkUpdateService.isApkUrl(info.downloadUrl)) {
      // iOS 没有系统包安装器、HarmonyOS 不允许三方装 HAP，仍走外部浏览器。
      await launchUrl(
        Uri.parse(info.downloadUrl),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    final int? id = await ApkUpdateService.startDownload(
      url: info.downloadUrl,
      fileName: ApkUpdateService.apkFileName(info.version),
    );
    if (!context.mounted) {
      return;
    }
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载启动失败，请检查网络后重试')),
      );
      return;
    }
    await showApkDownloadSheet(context);
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
                        title: s.t('settings_user_location'),
                        subtitle: s.t('settings_user_location_desc'),
                        trailing: Text(
                          settings.userLocation.isEmpty
                              ? s.t('settings_user_location_empty')
                              : settings.userLocation,
                          style: TextStyle(fontSize: 12, color: c.textMuted),
                        ),
                        onTap: () => _editUserLocation(context, settings, s),
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
                        title: s.t('settings_feature_safety'),
                        value: settings.featureSafety,
                        onChanged: (bool v) =>
                            settings.setFeatureBool(PreferencesService.keyFeatureSafety, v),
                      ),
                    ],
                  ),
                  _SectionLabel(text: s.t('settings_section_voice')),
                  _SettingsCard(
                    children: <Widget>[
                      _SettingsRow(
                        title: s.t('settings_tts_voice'),
                        trailing: Text(
                          settings.ttsVoice == 'tide'
                              ? s.t('settings_voice_tide')
                              : s.t('settings_voice_stella'),
                          style: TextStyle(fontSize: 12, color: c.textMuted),
                        ),
                        onTap: () => _pickTtsVoice(context, settings, s),
                      ),
                    ],
                  ),
                  _SectionLabel(text: s.t('settings_section_security')),
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
                      if (settings.appLockEnabled)
                        _SettingsRow(
                          title: s.t('settings_app_lock_method'),
                          subtitle: settings.appLockAuthMode == appLockAuthBiometric
                              ? s.t('settings_app_lock_method_biometric')
                              : s.t('settings_app_lock_method_any'),
                          onTap: () =>
                              _pickAppLockAuthMode(context, settings, s),
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
                      // 下载中/已下载时常驻一行，方便从任何页面回来继续看进度或安装。
                      ValueListenableBuilder<ApkDownloadState>(
                        valueListenable: ApkUpdateService.state,
                        builder: (
                          BuildContext ctx,
                          ApkDownloadState state,
                          Widget? _,
                        ) {
                          if (!state.isActive && !state.isCompleted) {
                            return const SizedBox.shrink();
                          }
                          final bool done = state.isCompleted;
                          return _SettingsRow(
                            title: done ? '更新包已下载' : '正在下载更新',
                            subtitle: done
                                ? '点此打开系统安装页'
                                : '${state.sizeLabel} · ${state.percentLabel}（可后台下载）',
                            trailing: done
                                ? Icon(
                                    Icons.system_update_alt_rounded,
                                    size: 20,
                                    color: c.accent,
                                  )
                                : Text(
                                    state.percentLabel,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: c.accent,
                                    ),
                                  ),
                            onTap: () => done
                                ? installDownloadedUpdate(context)
                                : showApkDownloadSheet(context),
                          );
                        },
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