/// Provider categories surfaced in the add-provider sheet.
///
/// Business Rule: the app now ships DeepSeek only; the enum is kept as a single
/// value so the assets page does not need to special-case an empty category list.
enum ProviderCategory { cnOfficial }

/// Declarative description of one provider's balance endpoint.
class BalanceQueryConfig {
  const BalanceQueryConfig({
    required this.endpoint,
    this.responsePath,
    this.usedField,
    this.totalField,
    this.availableField,
    this.currencyField,
    this.defaultCurrency,
  });

  final String endpoint;
  final String? responsePath;
  final String? usedField;
  final String? totalField;
  final String? availableField;
  final String? currencyField;
  final String? defaultCurrency;
}

class ProviderDefinition {
  const ProviderDefinition({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.category,
    required this.balanceConfig,
    required this.brandColor,
    required this.websiteUrl,
    required this.iconAsset,
    this.supportsThinking = false,
    this.chatEndpoint = '/v1/chat/completions',
    this.modelsEndpoint = '/v1/models',
  });

  final String id;
  final String name;
  final String baseUrl;
  final ProviderCategory category;
  final BalanceQueryConfig balanceConfig;
  final String brandColor;
  final String websiteUrl;
  final String iconAsset;
  final bool supportsThinking;

  /// Provider-specific OpenAI-compatible chat path.
  final String chatEndpoint;
  final String modelsEndpoint;

  String get categoryLabel => '国内官方';
}

class BalanceInfo {
  const BalanceInfo({
    required this.providerId,
    required this.total,
    required this.used,
    required this.available,
    required this.currency,
    required this.updatedAt,
  });

  final String providerId;
  final double total;
  final double used;
  final double available;
  final String currency;
  final String updatedAt;

  double get usagePercentage {
    if (total <= 0) {
      return 0;
    }
    return (used / total) * 100;
  }
}

String currencySymbol(String currency) => currency == 'CNY' ? '¥' : '\$';

/// Display unit: the app only deals in real currencies now.
String unitLabel(String currency) => currency;

/// Single formatting entry shared by cards and the hero summary.
String formatAmountText(String currency, double value) => value.toStringAsFixed(2);

/// Closed-set registry: DeepSeek is the only supported provider.
const List<ProviderDefinition> providers = <ProviderDefinition>[
  ProviderDefinition(
    id: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    category: ProviderCategory.cnOfficial,
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
];

ProviderDefinition? findProvider(String id) {
  for (final ProviderDefinition p in providers) {
    if (p.id == id) {
      return p;
    }
  }
  return null;
}

/// DeepSeek is the only provider and always supports thinking mode.
bool isThinkingSupported(String providerId, String modelId) =>
    providerId == 'deepseek';
