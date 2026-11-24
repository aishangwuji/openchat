/// Provider categories surfaced in the add-provider sheet.
enum ProviderCategory { cnOfficial, aggregator }

enum BalanceQueryType {
  bearer,

  /// Browser cookie session (Baizhi Cloud wallet): the balance endpoint only
  /// accepts `Cookie`, never an API key, so it needs its own engine branch.
  cookieSession,
}

/// How the credential is presented on the wire.
enum CredentialKind { bearer, cookie }

/// Declarative description of one provider endpoint.
///
/// Business Rule: adding a Bearer provider is data only; the query engine
/// stays generic. Non-Bearer engines must add an explicit branch.
class BalanceQueryConfig {
  const BalanceQueryConfig({
    required this.endpoint,
    this.responsePath,
    this.useBearerPrefix,
    this.amountMultiplier,
    this.usedField,
    this.totalField,
    this.availableField,
    this.currencyField,
    this.defaultCurrency,
    this.successCodeField,
    this.successCodeValue,
    this.userAgent,
    this.temporaryCreditField,
    this.permanentCreditField,
    this.frozenCreditField,
    this.dailyClaimedField,
  });

  final String endpoint;
  final String? responsePath;
  final bool? useBearerPrefix;
  final double? amountMultiplier;
  final String? usedField;
  final String? totalField;
  final String? availableField;
  final String? currencyField;
  final String? defaultCurrency;
  final String? successCodeField;
  final int? successCodeValue;

  /// Cookie providers must reuse the UA of the browser that produced the
  /// cookie, otherwise the WAF rejects the request.
  final String? userAgent;

  /// Credit breakdown fields (Baizhi Cloud wallet). Values share
  /// [amountMultiplier] with the main balance (cents -> credits).
  final String? temporaryCreditField;
  final String? permanentCreditField;
  final String? frozenCreditField;
  final String? dailyClaimedField;
}

class ProviderDefinition {
  const ProviderDefinition({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.category,
    required this.balanceType,
    required this.balanceConfig,
    required this.brandColor,
    required this.websiteUrl,
    required this.iconAsset,
    this.supportsThinking = false,
    this.chatEndpoint = '/v1/chat/completions',
    this.modelsEndpoint = '/v1/models',
    this.credentialKind = CredentialKind.bearer,
    this.credentialRequiredFragment,
    this.checkinUrl,
    this.chatCapable = true,
  });

  final String id;
  final String name;
  final String baseUrl;
  final ProviderCategory category;
  final BalanceQueryType balanceType;
  final BalanceQueryConfig balanceConfig;
  final String brandColor;
  final String websiteUrl;
  final String iconAsset;
  final bool supportsThinking;

  /// Credential shape; defaults to Bearer for every legacy entry.
  final CredentialKind credentialKind;

  /// Substring the pasted credential must contain (e.g. `baizhi_session`),
  /// checked locally before any network call.
  final String? credentialRequiredFragment;

  /// Manual check-in page. Business Rule: the check-in endpoint triggers a
  /// captcha, so only the user in a browser can complete it — the app just
  /// opens the page and never signs in on the user's behalf.
  final String? checkinUrl;

  /// Whether the provider can serve OpenAI-compatible chat/model calls.
  ///
  /// Business Rule: balance-only providers (Baizhi cookie wallet) set this to
  /// false, otherwise the chat screen would send the session cookie as an API
  /// key to `/v1/models` and `/v1/chat/completions`.
  final bool chatCapable;

  /// Provider-specific OpenAI-compatible chat path.
  ///
  /// Business Rule: never assume every provider lives under `/v1`; OpenRouter
  /// uses `/api/v1` and Novita uses `/openai/v1`.
  final String chatEndpoint;
  final String modelsEndpoint;

  String get categoryLabel =>
      category == ProviderCategory.cnOfficial ? '国内官方' : 'API聚合';
}

/// Credit snapshot of a wallet-style provider (Baizhi Cloud).
class CreditDetail {
  const CreditDetail({
    required this.temporary,
    required this.permanent,
    required this.frozen,
    required this.dailyClaimed,
  });

  final double temporary;
  final double permanent;
  final double frozen;
  final bool dailyClaimed;
}

class BalanceInfo {
  const BalanceInfo({
    required this.providerId,
    required this.total,
    required this.used,
    required this.available,
    required this.currency,
    required this.updatedAt,
    this.credit,
  });

  final String providerId;
  final double total;
  final double used;
  final double available;
  final String currency;
  final String updatedAt;
  final CreditDetail? credit;

  double get usagePercentage {
    if (total <= 0) {
      return 0;
    }
    return (used / total) * 100;
  }
}

/// Placeholder currency for credit-style balances, kept distinct from real
/// currencies so they are never summed into money totals.
const String creditsUnit = 'CREDITS';

bool isCreditUnit(String currency) => currency == creditsUnit;

String currencySymbol(String currency) {
  if (currency == 'CNY') {
    return '¥';
  }
  // Credits carry no currency symbol, otherwise ¥/$ would read as real money.
  if (isCreditUnit(currency)) {
    return '';
  }
  return '\$';
}

/// Display unit: credits read as 「积分」, currencies echo their code.
String unitLabel(String currency) => isCreditUnit(currency) ? '积分' : currency;

/// Drops trailing zeros for credit values; keeps 2 decimals only when needed.
String formatCredit(double value) {
  final double rounded = (value * 100).round() / 100;
  if ((rounded - rounded.round()).abs() < 0.005) {
    return rounded.round().toString();
  }
  return rounded.toStringAsFixed(2);
}

/// Single formatting entry shared by cards and the hero summary.
String formatAmountText(String currency, double value) {
  if (isCreditUnit(currency)) {
    return formatCredit(value);
  }
  return value.toStringAsFixed(2);
}

/// Closed-set registry ported from the HarmonyOS implementation.
const List<ProviderDefinition> providers = <ProviderDefinition>[
  ProviderDefinition(
    id: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    category: ProviderCategory.cnOfficial,
    balanceType: BalanceQueryType.bearer,
    balanceConfig: BalanceQueryConfig(
      endpoint: '/user/balance',
      responsePath: 'balance_infos',
      availableField: 'total_balance',
      currencyField: 'currency',
      defaultCurrency: 'CNY',
    ),
    brandColor: '#4D6BFE',
    websiteUrl: 'https://platform.deepseek.com',
    iconAsset: 'assets/providers/deepseek.png',
    supportsThinking: true,
    chatEndpoint: '/chat/completions',
    modelsEndpoint: '/models',
  ),
  ProviderDefinition(
    id: 'stepfun',
    name: '阶跃 StepFun',
    baseUrl: 'https://api.stepfun.com',
    category: ProviderCategory.cnOfficial,
    balanceType: BalanceQueryType.bearer,
    balanceConfig: BalanceQueryConfig(
      endpoint: '/v1/accounts',
      availableField: 'balance',
      defaultCurrency: 'CNY',
    ),
    brandColor: '#0EA5E9',
    websiteUrl: 'https://platform.stepfun.com',
    iconAsset: 'assets/providers/stepfun.png',
  ),
  ProviderDefinition(
    id: 'openrouter',
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai',
    category: ProviderCategory.aggregator,
    balanceType: BalanceQueryType.bearer,
    balanceConfig: BalanceQueryConfig(
      endpoint: '/api/v1/credits',
      responsePath: 'data',
      totalField: 'total_credits',
      usedField: 'total_usage',
      defaultCurrency: 'USD',
    ),
    brandColor: '#E85D3D',
    websiteUrl: 'https://openrouter.ai',
    iconAsset: 'assets/providers/openrouter.png',
    chatEndpoint: '/api/v1/chat/completions',
    modelsEndpoint: '/api/v1/models',
  ),
  ProviderDefinition(
    id: 'novita',
    name: 'Novita AI',
    baseUrl: 'https://api.novita.ai',
    category: ProviderCategory.aggregator,
    balanceType: BalanceQueryType.bearer,
    balanceConfig: BalanceQueryConfig(
      endpoint: '/v3/user/balance',
      availableField: 'availableBalance',
      amountMultiplier: 0.0001,
      defaultCurrency: 'USD',
    ),
    brandColor: '#10B981',
    websiteUrl: 'https://novita.ai',
    iconAsset: 'assets/providers/novita.png',
    chatEndpoint: '/openai/v1/chat/completions',
    modelsEndpoint: '/openai/v1/models',
  ),
  ProviderDefinition(
    id: 'kimi',
    name: 'Kimi',
    baseUrl: 'https://api.moonshot.cn',
    category: ProviderCategory.cnOfficial,
    balanceType: BalanceQueryType.bearer,
    balanceConfig: BalanceQueryConfig(
      endpoint: '/v1/users/me/balance',
      responsePath: 'data',
      availableField: 'available_balance',
      defaultCurrency: 'CNY',
      successCodeField: 'code',
      successCodeValue: 0,
    ),
    brandColor: '#1A1A1A',
    websiteUrl: 'https://platform.kimi.com',
    iconAsset: 'assets/providers/kimi.png',
    supportsThinking: true,
  ),
  ProviderDefinition(
    id: 'mimo',
    name: '小米 MiMo',
    baseUrl: 'https://api.xiaomimimo.com',
    category: ProviderCategory.cnOfficial,
    balanceType: BalanceQueryType.bearer,
    balanceConfig: BalanceQueryConfig(
      endpoint: '/v1/models',
      availableField: '',
      defaultCurrency: 'CNY',
    ),
    brandColor: '#FF6900',
    websiteUrl: 'https://mimo.mi.com',
    iconAsset: 'assets/providers/mimo.png',
    supportsThinking: true,
  ),
  ProviderDefinition(
    // Baizhi Cloud: wallet endpoint only accepts the browser session cookie
    // (`baizhi_session`); credits are returned in cents.
    id: 'baizhi',
    name: '百智云',
    baseUrl: 'https://baizhi.cloud',
    category: ProviderCategory.cnOfficial,
    balanceType: BalanceQueryType.cookieSession,
    balanceConfig: BalanceQueryConfig(
      endpoint: '/api/v1/user/wallet/balance',
      responsePath: 'data',
      availableField: 'available_credit_cents',
      // Cents -> credits (100 cents = 1 credit/yuan).
      amountMultiplier: 0.01,
      defaultCurrency: creditsUnit,
      successCodeField: 'code',
      successCodeValue: 0,
      userAgent:
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:160.0) '
          'Gecko/20100101 Firefox/160.0',
      temporaryCreditField: 'temporary_credit_cents',
      permanentCreditField: 'permanent_credit_cents',
      frozenCreditField: 'frozen_credit_cents',
      dailyClaimedField: 'daily_temporary_credit_claimed',
    ),
    brandColor: '#0FA47F',
    websiteUrl: 'https://baizhi.cloud',
    iconAsset: 'assets/providers/baizhi.png',
    credentialKind: CredentialKind.cookie,
    credentialRequiredFragment: 'baizhi_session',
    checkinUrl: 'https://baizhi.cloud/console/apps',
    // The stored credential is a browser session cookie, not an API key.
    chatCapable: false,
  ),
];

/// Providers that can legitimately serve chat / model-list calls.
///
/// Business Rule: balance-only providers (`chatCapable == false`) must never
/// reach the chat picker, so their cookie never travels to chat endpoints.
List<ProviderDefinition> get chatProviders => providers
    .where((ProviderDefinition p) => p.chatCapable)
    .toList(growable: false);

const List<String> mimoThinkingModels = <String>[
  'mimo-v2.6-flash',
  'mimo-v2.6-pro',
  'mimo-v2.6-pro-ultraspeed',
  'mimo-v2.5-pro',
  'mimo-v2.5',
];

const List<String> kimiThinkingModels = <String>[
  'kimi-k3',
  'kimi-k2.7-code',
  'kimi-k2.7-code-highspeed',
  'kimi-k2.6',
];

ProviderDefinition? findProvider(String id) {
  for (final ProviderDefinition p in providers) {
    if (p.id == id) {
      return p;
    }
  }
  return null;
}

bool isThinkingSupported(String providerId, String modelId) {
  if (providerId == 'deepseek') {
    return true;
  }
  if (providerId == 'mimo') {
    if (modelId.isEmpty || modelId == '选择模型') {
      return true;
    }
    final String lower = modelId.toLowerCase().trim();
    for (final String m in mimoThinkingModels) {
      if (lower == m || lower.contains(m)) {
        return true;
      }
    }
    return lower.contains('mimo-v2.6') || lower.contains('mimo-v2.5');
  }
  if (providerId == 'kimi') {
    if (modelId.isEmpty || modelId == '选择模型') {
      return true;
    }
    final String lower = modelId.toLowerCase().trim();
    for (final String m in kimiThinkingModels) {
      if (lower == m || lower.contains(m)) {
        return true;
      }
    }
    return lower.contains('k3') || lower.contains('k2.7') || lower.contains('k2.6');
  }
  return findProvider(providerId)?.supportsThinking == true;
}
