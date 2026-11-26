import 'package:balance_app/data/services/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 官方 TTS 单次上限是 10,000 个计费字符，汉字按 2 计；旧代码按 2000 个
/// UTF-16 code unit 截断，长回答会被静默砍掉。
void main() {
  test('计费字符按汉字 2、其他 1 计算', () {
    expect(TtsService.billingChars('你好'), 4);
    expect(TtsService.billingChars('ab 1'), 4);
    expect(TtsService.billingChars('你好ab'), 6);
  });

  test('中文按 5000 字封顶（10000 计费字符）', () {
    final String clipped = TtsService.clipForTts('汉' * 6000);
    expect(clipped.runes.length, 5000);
    expect(TtsService.billingChars(clipped), 10000);
  });

  test('英文按 10000 字符封顶', () {
    final String clipped = TtsService.clipForTts('a' * 12000);
    expect(clipped.length, 10000);
  });

  test('未超限时原样返回', () {
    expect(TtsService.clipForTts('你好，世界'), '你好，世界');
  });
}
