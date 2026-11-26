/*
 * ProviderRegistry.ets
 *
 * 单服务商注册表：应用只支持 DeepSeek。
 *
 * Business Rule: 余额查询统一走 Bearer 引擎；不再保留 Cookie / 积分 / 多厂商分支。
 */

export enum ProviderCategory {
  CnOfficial = '国内官方',
}

export interface BalanceQueryConfig {
  /** 余额端点路径，拼接到 baseUrl 后（绝对 URL 也允许）。 */
  endpoint: string;
  /** JSON 导航路径，如 'data'、'balance_infos'；缺省为整包。 */
  responsePath?: string;
  /** 已用字段名；缺省时按 total-available 推导。 */
  usedField?: string;
  /** 总额字段名。 */
  totalField?: string;
  /** 可用/余额字段名；数组响应时对数组元素求和。 */
  availableField?: string;
  /** 币种字段名；缺省用 defaultCurrency。 */
  currencyField?: string;
  /** 兜底币种。 */
  defaultCurrency?: string;
}

export interface ProviderDefinition {
  id: string;
  name: string;
  baseUrl: string;
  category: ProviderCategory;
  balanceConfig: BalanceQueryConfig;
  brandColor: string;
  websiteUrl: string;
  /** 品牌图标资源名（entry resources/base/media 下的 png，不带后缀）。 */
  icon: string;
  supportsThinking?: boolean;
}

/** 统一余额模型。 */
export interface BalanceInfo {
  providerId: string;
  total: number;
  used: number;
  available: number;
  currency: string;
  updatedAt: string;
}

export function usagePercentage(info: BalanceInfo): number {
  if (info.total > 0) {
    return (info.used / info.total) * 100.0;
  }
  return 0.0;
}

export function currencySymbol(currency: string): string {
  if (currency === 'CNY') {
    return '¥';
  }
  return '$';
}

/** 展示单位：货币回显币种代码。 */
export function unitLabel(currency: string): string {
  return currency;
}

/** 卡片/Hero 的统一数值文案：货币固定两位小数。 */
export function formatAmountText(currency: string, value: number): string {
  return value.toFixed(2);
}

/** 唯一服务商：DeepSeek。 */
export const PROVIDERS: ProviderDefinition[] = [
  {
    id: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    category: ProviderCategory.CnOfficial,
    balanceConfig: {
      endpoint: '/user/balance',
      responsePath: 'balance_infos',
      availableField: 'total_balance',
      currencyField: 'currency',
      defaultCurrency: 'CNY',
    },
    brandColor: '#4D6BFE',
    icon: 'deepseek',
    websiteUrl: 'https://platform.deepseek.com',
    supportsThinking: true,
  },
];

/** DeepSeek 是唯一服务商，固定支持思考模式。 */
export function isThinkingSupported(providerId: string, modelId?: string): boolean {
  return providerId === 'deepseek';
}

export function findProvider(id: string): ProviderDefinition | undefined {
  let i: number = 0;
  while (i < PROVIDERS.length) {
    if (PROVIDERS[i].id === id) {
      return PROVIDERS[i];
    }
    i += 1;
  }
  return undefined;
}

/** 可参与对话的服务商（只剩 DeepSeek）。 */
export function chatProviders(): ProviderDefinition[] {
  const out: ProviderDefinition[] = [];
  let i: number = 0;
  while (i < PROVIDERS.length) {
    out.push(PROVIDERS[i]);
    i += 1;
  }
  return out;
}

export function categoryLabel(cat: ProviderCategory): string {
  return '国内官方';
}
