import 'package:balance_app/core/i18n/settings_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('voice section follows the HarmonyOS wording', () {
    final SettingsStrings zh = SettingsStrings('zh-CN');
    expect(zh.t('settings_section_voice'), '语音');
    expect(zh.t('settings_tts_voice'), '朗读音色');
    expect(zh.t('settings_voice_stella'), '海星（女声）');
    expect(zh.t('settings_voice_stella_desc'), '默认音色，语气自然平稳');
    expect(zh.t('settings_voice_tide'), '暗潮（男声）');
    expect(zh.t('settings_voice_tide_desc'), '偏低沉的男声');
  });

  test('voice section falls back to English labels', () {
    final SettingsStrings en = SettingsStrings('en-US');
    expect(en.t('settings_tts_voice'), 'Read-aloud Voice');
    expect(en.t('settings_voice_stella'), 'Stella (female)');
    expect(en.t('settings_voice_tide'), 'Tide (male)');
  });
}
