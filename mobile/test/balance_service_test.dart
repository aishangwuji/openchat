import 'package:balance_app/data/models/provider.dart';
import 'package:balance_app/data/services/balance_service.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderDefinition deepseek() {
  final ProviderDefinition? def = findProvider('deepseek');
  if (def == null) {
    throw StateError('missing deepseek provider');
  }
  return def;
}

void main() {
  group('provider registry', () {
    test('only DeepSeek is registered', () {
      expect(providers.length, 1);
      expect(providers.single.id, 'deepseek');
      for (final String gone in <String>[
        'stepfun',
        'openrouter',
        'novita',
        'kimi',
        'mimo',
        'baizhi',
      ]) {
        expect(findProvider(gone), isNull);
      }
    });

    test('DeepSeek uses its own OpenAI-compatible paths', () {
      expect(deepseek().chatEndpoint, '/chat/completions');
      expect(deepseek().modelsEndpoint, '/models');
      expect(deepseek().balanceConfig.endpoint, '/user/balance');
    });

    test('DeepSeek supports thinking; other ids do not', () {
      expect(isThinkingSupported('deepseek', 'deepseek-flash'), true);
      expect(isThinkingSupported('kimi', 'kimi-k3'), false);
    });
  });

  group('parseBalanceBody', () {
    test('sums DeepSeek balance_infos array', () {
      final BalanceInfo info = parseBalanceBody(
        deepseek(),
        '{"is_available":true,"balance_infos":['
        '{"currency":"CNY","total_balance":"12.34"},'
        '{"currency":"CNY","total_balance":"7.66"}]}',
      );
      expect(info.available, closeTo(20, 0.0001));
      expect(info.total, closeTo(20, 0.0001));
      expect(info.currency, 'CNY');
      expect(info.used, 0);
      expect(info.providerId, 'deepseek');
    });

    test('uses the currency from the account entry', () {
      final BalanceInfo info = parseBalanceBody(
        deepseek(),
        '{"balance_infos":[{"currency":"USD","total_balance":"3.5"}]}',
      );
      expect(info.available, closeTo(3.5, 0.0001));
      expect(info.currency, 'USD');
    });

    test('empty balance list yields zero with default currency', () {
      final BalanceInfo info = parseBalanceBody(
        deepseek(),
        '{"balance_infos":[]}',
      );
      expect(info.available, 0);
      expect(info.total, 0);
      expect(info.currency, 'CNY');
    });

    test('rejects malformed JSON', () {
      expect(
        () => parseBalanceBody(deepseek(), 'not-json'),
        throwsA(isA<DeterministicException>()),
      );
      expect(
        () => parseBalanceBody(deepseek(), '[]'),
        throwsA(isA<DeterministicException>()),
      );
    });
  });

  group('formatting', () {
    test('money keeps two decimals', () {
      expect(formatAmountText('CNY', 12.3), '12.30');
      expect(currencySymbol('CNY'), '¥');
      expect(currencySymbol('USD'), '\$');
      expect(unitLabel('CNY'), 'CNY');
    });
  });

  group('fetchProviderBalance boundary', () {
    test('rejects an empty key before networking', () async {
      final ProviderBalanceResult result =
          await fetchProviderBalance('deepseek', '   ');
      expect(result.success, false);
      expect(result.error, 'API key is empty');
    });

    test('rejects an unknown provider before networking', () async {
      final ProviderBalanceResult result =
          await fetchProviderBalance('unknown', 'sk-test');
      expect(result.success, false);
      expect(result.error, 'Unknown provider');
    });
  });
}
