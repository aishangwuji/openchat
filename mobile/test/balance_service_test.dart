import 'package:balance_app/data/models/provider.dart';
import 'package:balance_app/data/services/balance_service.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderDefinition provider(String id) {
  final ProviderDefinition? def = findProvider(id);
  if (def == null) {
    throw StateError('missing provider $id');
  }
  return def;
}

void main() {
  group('parseBalanceBody', () {
    test('sums DeepSeek balance_infos array', () {
      final BalanceInfo info = parseBalanceBody(
        provider('deepseek'),
        '{"is_available":true,"balance_infos":['
        '{"currency":"CNY","total_balance":"12.34"},'
        '{"currency":"CNY","total_balance":"7.66"}]}',
      );
      expect(info.available, closeTo(20, 0.0001));
      expect(info.total, closeTo(20, 0.0001));
      expect(info.currency, 'CNY');
      expect(info.used, 0);
    });

    test('derives available for OpenRouter credits', () {
      final BalanceInfo info = parseBalanceBody(
        provider('openrouter'),
        '{"data":{"total_credits":50,"total_usage":12.5}}',
      );
      expect(info.total, closeTo(50, 0.0001));
      expect(info.used, closeTo(12.5, 0.0001));
      expect(info.available, closeTo(37.5, 0.0001));
      expect(info.currency, 'USD');
    });

    test('applies Novita unit multiplier', () {
      final BalanceInfo info = parseBalanceBody(
        provider('novita'),
        '{"availableBalance":1234567}',
      );
      expect(info.available, closeTo(123.4567, 0.0001));
      expect(info.currency, 'USD');
    });

    test('rejects Kimi business failure code', () {
      expect(
        () => parseBalanceBody(
          provider('kimi'),
          '{"code":1,"data":{"available_balance":9.5}}',
        ),
        throwsA(isA<DeterministicException>()),
      );
    });

    test('accepts Kimi success code zero', () {
      final BalanceInfo info = parseBalanceBody(
        provider('kimi'),
        '{"code":0,"data":{"available_balance":9.5}}',
      );
      expect(info.available, closeTo(9.5, 0.0001));
      expect(info.currency, 'CNY');
    });

    test('rejects malformed JSON', () {
      expect(
        () => parseBalanceBody(provider('deepseek'), 'not-json'),
        throwsA(isA<DeterministicException>()),
      );
    });

    test('parses Baizhi wallet credits from cents', () {
      final BalanceInfo info = parseBalanceBody(
        provider('baizhi'),
        '{"code":0,"message":"success","data":{'
        '"user_id":107295191494725,'
        '"temporary_credit_cents":10000,'
        '"permanent_credit_cents":63500,'
        '"frozen_credit_cents":0,'
        '"available_credit_cents":73500,'
        '"daily_temporary_credit_claimed":true}}',
      );
      // 73500 cents -> 735 credits (100 cents = 1 credit).
      expect(info.available, closeTo(735, 0.0001));
      expect(info.total, closeTo(735, 0.0001));
      expect(info.used, 0);
      expect(info.currency, creditsUnit);
      expect(info.credit, isNotNull);
      expect(info.credit!.temporary, closeTo(100, 0.0001));
      expect(info.credit!.permanent, closeTo(635, 0.0001));
      expect(info.credit!.frozen, 0);
      expect(info.credit!.dailyClaimed, true);
    });

    test('marks Baizhi daily credits as unclaimed', () {
      final BalanceInfo info = parseBalanceBody(
        provider('baizhi'),
        '{"code":0,"data":{"available_credit_cents":100,'
        '"daily_temporary_credit_claimed":false}}',
      );
      expect(info.credit!.dailyClaimed, false);
      expect(info.credit!.temporary, 0);
    });

    test('rejects expired Baizhi session code', () {
      expect(
        () => parseBalanceBody(
          provider('baizhi'),
          '{"code":401,"message":"unauthorized","data":null}',
        ),
        throwsA(
          isA<DeterministicException>().having(
            (DeterministicException e) => e.message,
            'message',
            contains('登录态失效'),
          ),
        ),
      );
    });
  });

  group('credit formatting', () {
    test('drops trailing zeros for whole credits', () {
      expect(formatCredit(735), '735');
      expect(formatCredit(735.5), '735.50');
      expect(formatCredit(0), '0');
    });

    test('currency and credit units stay separated', () {
      expect(formatAmountText('CNY', 12.3), '12.30');
      expect(formatAmountText(creditsUnit, 735), '735');
      expect(currencySymbol(creditsUnit), '');
      expect(unitLabel(creditsUnit), '积分');
      expect(unitLabel('CNY'), 'CNY');
    });
  });

  group('credential normalization', () {
    test('strips a pasted Cookie: prefix and line breaks', () {
      expect(
        normalizeCredential(
          'Cookie: baizhi_session=abc; sl-session=xyz\r\n',
          CredentialKind.cookie,
        ),
        'baizhi_session=abc; sl-session=xyz',
      );
    });

    test('keeps bearer keys untouched apart from trimming', () {
      expect(
        normalizeCredential('  sk-test  ', CredentialKind.bearer),
        'sk-test',
      );
    });
  });

  group('provider registry', () {
    test('uses provider-specific OpenAI-compatible paths', () {
      expect(provider('openrouter').chatEndpoint, '/api/v1/chat/completions');
      expect(provider('openrouter').modelsEndpoint, '/api/v1/models');
      expect(provider('novita').chatEndpoint, '/openai/v1/chat/completions');
      expect(provider('novita').modelsEndpoint, '/openai/v1/models');
      expect(provider('deepseek').chatEndpoint, '/chat/completions');
      expect(provider('deepseek').modelsEndpoint, '/models');
    });

    test('Baizhi is a cookie provider with a check-in page', () {
      final ProviderDefinition baizhi = provider('baizhi');
      expect(baizhi.balanceType, BalanceQueryType.cookieSession);
      expect(baizhi.credentialKind, CredentialKind.cookie);
      expect(baizhi.credentialRequiredFragment, 'baizhi_session');
      expect(baizhi.checkinUrl, 'https://baizhi.cloud/console/apps');
      expect(
        baizhi.balanceConfig.endpoint,
        '/api/v1/user/wallet/balance',
      );
    });

    test('existing providers stay bearer', () {
      expect(provider('deepseek').credentialKind, CredentialKind.bearer);
      expect(provider('deepseek').checkinUrl, isNull);
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

    test('rejects an empty Baizhi cookie', () async {
      final ProviderBalanceResult result =
          await fetchProviderBalance('baizhi', '  ');
      expect(result.success, false);
      expect(result.error, contains('Cookie 为空'));
    });

    test('rejects a Baizhi cookie without baizhi_session', () async {
      final ProviderBalanceResult result =
          await fetchProviderBalance('baizhi', 'sk-not-a-cookie');
      expect(result.success, false);
      expect(result.error, contains('baizhi_session'));
    });
  });
}
