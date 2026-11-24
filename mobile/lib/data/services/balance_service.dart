import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/provider.dart';

class ProviderBalanceResult {
  const ProviderBalanceResult({required this.success, this.info, this.error});

  final bool success;
  final BalanceInfo? info;
  final String? error;
}

/// Deterministic failures (bad key, unknown provider, auth, non-2xx, bad JSON)
/// are returned as `success: false`. Transient transport failures are thrown
/// so the caller can keep the last good value and offer a retry.
class AuthFailedException implements Exception {
  const AuthFailedException(this.status);
  final int status;

  @override
  String toString() => 'Authentication failed (HTTP $status)';
}

class DeterministicException implements Exception {
  const DeterministicException(this.message);
  final String message;

  @override
  String toString() => message;
}

const Duration _timeout = Duration(seconds: 15);

double _toNumber(Object? value) {
  if (value is num) {
    return value.toDouble().isFinite ? value.toDouble() : 0;
  }
  if (value is String) {
    final double parsed = double.tryParse(value.trim()) ?? 0;
    return parsed.isFinite ? parsed : 0;
  }
  return 0;
}

Object? _fieldOf(Object? object, String? field) {
  if (object is! Map || field == null || field.isEmpty) {
    return null;
  }
  return object[field];
}

Object? _navigatePath(Object? root, String? path) {
  if (path == null || path.isEmpty) {
    return root;
  }
  Object? current = root;
  for (final String key in path.split('.')) {
    current = _fieldOf(current, key);
    if (current == null) {
      return null;
    }
  }
  return current;
}

String _buildUrl(String baseUrl, String endpoint) {
  if (endpoint.startsWith('http')) {
    return endpoint;
  }
  if (endpoint.isEmpty) {
    return baseUrl;
  }
  final String base =
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  return '$base$endpoint';
}

/// Boundary normalization: strips a pasted `Cookie:` prefix and line breaks.
///
/// Reason: users often copy the whole DevTools line "Cookie: a=b; c=d"; that
/// value would otherwise be sent verbatim as the header value.
String normalizeCredential(String raw, CredentialKind kind) {
  if (kind != CredentialKind.cookie) {
    return raw.trim();
  }
  final String flat = raw.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  if (flat.toLowerCase().startsWith('cookie:')) {
    return flat.substring(7).trim();
  }
  return flat;
}

Map<String, String> _bearerHeaders(String apiKey, bool bearerPrefix) {
  return <String, String>{
    'Authorization': bearerPrefix ? 'Bearer $apiKey' : apiKey,
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };
}

Map<String, String> _cookieHeaders(String cookie, String userAgent) {
  // Reason: Baizhi Cloud's WAF pairs the cookie with the browser UA.
  return <String, String>{
    'Cookie': cookie,
    'User-Agent': userAgent,
    'Accept': '*/*',
  };
}

/// Single GET channel: network / auth / non-2xx failures are collapsed into
/// the same error channels for both engines.
Future<String> _getText(
  ProviderDefinition def,
  Uri uri,
  Map<String, String> headers,
) async {
  final http.Client client = http.Client();
  late final http.Response response;
  try {
    response = await client.get(uri, headers: headers).timeout(_timeout);
  } on TimeoutException {
    rethrow;
  } catch (error) {
    debugPrint('BalanceService: network error provider=${def.id} error=$error');
    rethrow;
  } finally {
    client.close();
  }

  if (response.statusCode == 401 || response.statusCode == 403) {
    throw AuthFailedException(response.statusCode);
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw DeterministicException(
      'API error (HTTP ${response.statusCode}): '
      '${_truncate(response.body)}',
    );
  }
  return response.body;
}

Future<BalanceInfo> _queryBearer(ProviderDefinition def, String apiKey) async {
  final BalanceQueryConfig config = def.balanceConfig;
  final Uri uri = Uri.parse(_buildUrl(def.baseUrl, config.endpoint));
  final bool bearer = config.useBearerPrefix ?? true;
  final String body = await _getText(def, uri, _bearerHeaders(apiKey, bearer));
  return parseBalanceBody(def, body);
}

/// Cookie engine: `Cookie` header + browser UA + the shared parser.
Future<BalanceInfo> _queryCookieSession(
  ProviderDefinition def,
  String cookie,
) async {
  final BalanceQueryConfig config = def.balanceConfig;
  final Uri uri = Uri.parse(_buildUrl(def.baseUrl, config.endpoint));
  final String userAgent = config.userAgent ?? _defaultUserAgent;
  final String body = await _getText(def, uri, _cookieHeaders(cookie, userAgent));
  return parseBalanceBody(def, body);
}

const String _defaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:160.0) '
    'Gecko/20100101 Firefox/160.0';

/// Pure response parser extracted for unit tests.
///
/// Boundary contract: HTTP status is already validated; this function owns
/// JSON shape validation, business-code checks and value derivation.
@visibleForTesting
BalanceInfo parseBalanceBody(ProviderDefinition def, String body) {
  final BalanceQueryConfig config = def.balanceConfig;
  final Object? root;
  try {
    root = jsonDecode(body);
  } catch (_) {
    throw const DeterministicException('Failed to parse response');
  }
  if (root is! Map) {
    throw const DeterministicException('Failed to parse response');
  }

  final String? successField = config.successCodeField;
  final int? successValue = config.successCodeValue;
  if (successField != null && successValue != null) {
    final Object? code = root[successField];
    final bool ok = (code is num && code.toInt() == successValue) ||
        (code is String && code == successValue.toString());
    if (!ok) {
      // Reason: cookie failures are almost always expired sessions, so give an
      // actionable hint instead of a raw JSON slice.
      if (def.balanceType == BalanceQueryType.cookieSession) {
        throw const DeterministicException('登录态失效（Cookie 无效或已过期），请重新从浏览器复制');
      }
      throw DeterministicException(
        'API error (business code): ${_truncate(body)}',
      );
    }
  }

  final Object? target = _navigatePath(root, config.responsePath);
  double available = 0;
  double total = 0;
  double used = 0;
  String currency = config.defaultCurrency ?? 'CNY';

  if (target is List) {
    final String availKey = config.availableField?.isNotEmpty == true
        ? config.availableField!
        : 'total_balance';
    final String currencyKey = config.currencyField?.isNotEmpty == true
        ? config.currencyField!
        : 'currency';
    for (final Object? item in target) {
      if (item is Map) {
        final double balance = _toNumber(item[availKey]);
        available += balance;
        total += balance;
        final Object? c = item[currencyKey];
        if (c is String && c.isNotEmpty) {
          currency = c;
        }
      }
    }
  } else if (target is Map) {
    available = _toNumber(_fieldOf(target, config.availableField));
    total = _toNumber(_fieldOf(target, config.totalField));
    used = _toNumber(_fieldOf(target, config.usedField));
    if (config.currencyField != null) {
      final Object? c = _fieldOf(target, config.currencyField);
      if (c is String && c.isNotEmpty) {
        currency = c;
      }
    }
  } else if (target is num) {
    available = target.toDouble();
    total = available;
  }

  final double multiplier = config.amountMultiplier ?? 1;
  available *= multiplier;
  total *= multiplier;
  used *= multiplier;

  if (config.usedField == null && total > 0 && used == 0 && total > available) {
    used = total - available;
  }
  if (config.availableField == null && total > 0 && available == 0 && used > 0) {
    available = total - used;
  }

  // Credit breakdown (Baizhi Cloud wallet): same multiplier as the main balance.
  CreditDetail? credit;
  final String? temporaryField = config.temporaryCreditField;
  if (temporaryField != null && target is Map) {
    final Object? claimed = config.dailyClaimedField == null
        ? null
        : _fieldOf(target, config.dailyClaimedField);
    credit = CreditDetail(
      temporary: _toNumber(_fieldOf(target, temporaryField)) * multiplier,
      permanent: _toNumber(_fieldOf(target, config.permanentCreditField)) *
          multiplier,
      frozen: _toNumber(_fieldOf(target, config.frozenCreditField)) *
          multiplier,
      dailyClaimed: claimed == true,
    );
  }

  final double finalTotal = total > 0 ? total : available + used;
  return BalanceInfo(
    providerId: def.id,
    total: finalTotal,
    used: used,
    available: available,
    currency: currency,
    updatedAt: _nowLabel(),
    credit: credit,
  );
}

String _truncate(String text) =>
    text.length <= 300 ? text : text.substring(0, 300);

String _nowLabel() {
  final DateTime now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)} '
      '${two(now.hour)}:${two(now.minute)}';
}

/// Public entry: validates inputs at the boundary before touching the network.
///
/// [credential] is an API key for Bearer providers and a browser cookie for
/// cookie-session providers (Baizhi Cloud).
Future<ProviderBalanceResult> fetchProviderBalance(
  String providerId,
  String credential,
) async {
  final ProviderDefinition? def = findProvider(providerId);
  if (def == null) {
    return const ProviderBalanceResult(
      success: false,
      error: 'Unknown provider',
    );
  }
  final String cred = normalizeCredential(credential, def.credentialKind);
  if (cred.isEmpty) {
    return ProviderBalanceResult(
      success: false,
      error: def.credentialKind == CredentialKind.cookie
          ? 'Cookie 为空，请从浏览器复制完整 Cookie'
          : 'API key is empty',
    );
  }
  if (def.credentialKind == CredentialKind.cookie) {
    final String? fragment = def.credentialRequiredFragment;
    if (fragment != null && !cred.contains(fragment)) {
      return ProviderBalanceResult(
        success: false,
        error: 'Cookie 缺少 $fragment，请确认复制的是登录后的完整 Cookie',
      );
    }
  }
  try {
    final BalanceInfo info = def.balanceType == BalanceQueryType.cookieSession
        ? await _queryCookieSession(def, cred)
        : await _queryBearer(def, cred);
    return ProviderBalanceResult(success: true, info: info);
  } on AuthFailedException catch (error) {
    return ProviderBalanceResult(success: false, error: error.toString());
  } on DeterministicException catch (error) {
    return ProviderBalanceResult(success: false, error: error.message);
  }
}
