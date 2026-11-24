/*
 * ProviderRegistry.ets
 *
 * 数据驱动的供应商注册表 —— 对齐智额 `models/provider_definition.dart` +
 * `config/provider_registry.dart` 的实现形式（酒馆/SillyTavern 相关除外）。
 *
 * Business Rule: 新增 Bearer 供应商只需追加一条 ProviderDefinition 数据，无需手写
 *   查询函数；查询语义由 BalanceQueryConfig 描述，通用 bearer 引擎执行。
 *   Cookie 类（如百智云）额外标注 credentialKind / balanceType，由 cookie 引擎执行。
 */

export enum ProviderCategory {
  CnOfficial = '国内官方',
}

export enum BalanceQueryType {
  Bearer = 'bearer',
  /**
   * 浏览器 Cookie 登录态（百智云钱包）。
   * Reason: 该厂商余额接口只认浏览器会话 Cookie，没有 API Key 通道，鉴权头也不同，
   *   必须走独立引擎分支，不能塞进 Bearer。
   */
  CookieSession = 'cookie_session',
}

/** 凭证形态：API Key（Authorization 头）或浏览器 Cookie（Cookie 头）。 */
export enum CredentialKind {
  Bearer = 'bearer',
  Cookie = 'cookie',
}

export interface BalanceQueryConfig {
  /** 余额端点路径，拼接到 baseUrl 后（绝对 URL 也允许）。 */
  endpoint: string;
  /** JSON 导航路径，如 'data'、'balance_infos'；缺省为整包。 */
  responsePath?: string;
  /** Authorization 头是否带 Bearer 前缀（智谱式裸 key 预留，当前均为 true）。 */
  useBearerPrefix?: boolean;
  /** 金额换算因子：厂商以最小货币单位返回时乘此系数（0.0001 表示单位是 0.0001 USD）。 */
  amountMultiplier?: number;
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
  /**
   * 业务成功码字段名（如 Kimi 的顶层 `code`）；缺省不校验。
   * Reason: Kimi 用 HTTP 200 + code!=0 表业务失败，与它家只看 HTTP 状态不同。
   */
  successCodeField?: string;
  /** 与 successCodeField 配对的成功值（如 Kimi 为 0）。 */
  successCodeValue?: number;
  /**
   * 请求头 User-Agent。
   * Business Rule: Cookie 类供应商需与获取 Cookie 的浏览器保持一致，否则会被 WAF 直接拦截。
   */
  userAgent?: string;
  /**
   * 积分明细字段（百智云钱包）。配置后解析结果附带 CreditDetail，
   * 与 availableField 共用 amountMultiplier 换算（分 → 积分）。
   */
  temporaryCreditField?: string;
  permanentCreditField?: string;
  frozenCreditField?: string;
  dailyClaimedField?: string;
}

export interface ProviderDefinition {
  id: string;
  name: string;
  baseUrl: string;
  category: ProviderCategory;
  balanceType: BalanceQueryType;
  balanceConfig: BalanceQueryConfig;
  /** 品牌色（卡片点缀用，十六进制字符串）。 */
  brandColor: string;
  websiteUrl: string;
  /**
   * 品牌图标资源名（entry resources/base/media 下的 png，不带后缀）。
   * Reason: ArkTS $r 不支持动态拼接，界面侧用静态映射取图（见 Index.providerIcon）。
   */
  icon: string;
  /**
   * 是否支持 OpenAI 格式思考模式（thinking/reasoning_effort）。
   * Business Rule: 仅对官方明确支持该扩展的厂商下发思考参数，避免对
   *   未知厂商透传非标准字段导致 400。
   */
  supportsThinking?: boolean;
  /** 凭证形态；缺省按 Bearer 处理（兼容既有条目）。 */
  credentialKind?: CredentialKind;
  /**
   * 凭证必须包含的片段，用于边界校验（如 Cookie 必须含 `baizhi_session`）。
   * Reason: 粘错内容（贴成 API Key 或半截 Cookie）应在本地直接拒绝，不进网络层。
   */
  credentialRequiredFragment?: string;
  /**
   * 手动签到页地址；配置后卡片展示「去签到」。
   * Business Rule: 签到接口会触发验证码，只能在浏览器里由用户本人完成人机验证，
   *   应用只负责跳转，绝不代签或绕过验证。
   */
  checkinUrl?: string;
  /**
   * 是否具备 OpenAI 兼容对话能力（可出现在 ChatView 的服务商列表）；缺省 true。
   * Business Rule: 纯余额类供应商（如百智云 Cookie 钱包）必须置 false，否则聊天侧会把
   *   Cookie 当成 API Key 发到 /v1/models、/v1/chat/completions，既发错接口也泄露登录态。
   */
  chatCapable?: boolean;
}

/** 积分明细（百智云钱包的一次快照）。 */
export interface CreditDetail {
  temporary: number;
  permanent: number;
  frozen: number;
  dailyClaimed: boolean;
}

/** 统一余额模型 —— 对齐智额 `models/balance_info.dart`。 */
export interface BalanceInfo {
  providerId: string;
  total: number;
  used: number;
  available: number;
  currency: string;
  updatedAt: string;
  /** 积分明细；仅配置了积分字段的供应商返回。 */
  credit?: CreditDetail;
}

export function usagePercentage(info: BalanceInfo): number {
  if (info.total > 0) {
    return (info.used / info.total) * 100.0;
  }
  return 0.0;
}

/** 积分/点数类余额的币种占位符（区别于真实货币，避免被当金额汇总）。 */
export const CREDITS_UNIT: string = 'CREDITS';

export function isCreditUnit(currency: string): boolean {
  return currency === CREDITS_UNIT;
}

export function currencySymbol(currency: string): string {
  if (currency === 'CNY') {
    return '¥';
  }
  // 积分不挂货币符号，否则 ¥/$ 会误导成真钱。
  if (isCreditUnit(currency)) {
    return '';
  }
  return '$';
}

/** 展示单位：积分显示「积分」，货币回显币种代码。 */
export function unitLabel(currency: string): string {
  return isCreditUnit(currency) ? '积分' : currency;
}

/** 积分去尾：整数不显示 .00，有零头才保留两位。 */
export function formatCredit(value: number): string {
  const rounded: number = Math.round(value * 100) / 100;
  if (Math.abs(rounded - Math.round(rounded)) < 0.005) {
    return `${Math.round(rounded)}`;
  }
  return rounded.toFixed(2);
}

/** 卡片/Hero 的统一数值文案：积分走整数优先，货币固定两位小数。 */
export function formatAmountText(currency: string, value: number): string {
  if (isCreditUnit(currency)) {
    return formatCredit(value);
  }
  return value.toFixed(2);
}

/** Reason: 前 3 家配置逐项对照智额 registry（endpoint/responsePath/字段名/换算因子一致）；
 *   百智云为本仓库新增（Cookie 登录态 + 积分口径），无智额对照。 */
export const PROVIDERS: ProviderDefinition[] = [
  {
    id: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    category: ProviderCategory.CnOfficial,
    balanceType: BalanceQueryType.Bearer,
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
  {
    id: 'kimi',
    name: 'Kimi',
    baseUrl: 'https://api.moonshot.cn',
    category: ProviderCategory.CnOfficial,
    balanceType: BalanceQueryType.Bearer,
    balanceConfig: {
      endpoint: '/v1/users/me/balance',
      responsePath: 'data',
      availableField: 'available_balance',
      defaultCurrency: 'CNY',
      successCodeField: 'code',
      successCodeValue: 0,
    },
    brandColor: '#1A1A1A',
    icon: 'kimi',
    websiteUrl: 'https://platform.kimi.com',
    supportsThinking: true,
  },
  {
    id: 'mimo',
    name: '小米 MiMo',
    baseUrl: 'https://api.xiaomimimo.com',
    category: ProviderCategory.CnOfficial,
    balanceType: BalanceQueryType.Bearer,
    balanceConfig: {
      endpoint: '/v1/models',
      availableField: '',
      defaultCurrency: 'CNY',
    },
    brandColor: '#FF6900',
    icon: 'mimo',
    websiteUrl: 'https://mimo.mi.com',
    supportsThinking: true,
  },
  {
    // 百智云：余额接口只认浏览器会话 Cookie（baizhi_session），以「分」计积分。
    // 签到接口会触发验证码，签到只能由用户在浏览器完成，故只提供跳转入口。
    id: 'baizhi',
    name: '百智云',
    baseUrl: 'https://baizhi.cloud',
    category: ProviderCategory.CnOfficial,
    balanceType: BalanceQueryType.CookieSession,
    balanceConfig: {
      endpoint: '/api/v1/user/wallet/balance',
      responsePath: 'data',
      availableField: 'available_credit_cents',
      // Reason: 字段单位是「分」，100 分 = 1 积分/元；除以 100 后按积分展示。
      amountMultiplier: 0.01,
      defaultCurrency: CREDITS_UNIT,
      successCodeField: 'code',
      successCodeValue: 0,
      userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:160.0) Gecko/20100101 Firefox/160.0',
      temporaryCreditField: 'temporary_credit_cents',
      permanentCreditField: 'permanent_credit_cents',
      frozenCreditField: 'frozen_credit_cents',
      dailyClaimedField: 'daily_temporary_credit_claimed',
    },
    brandColor: '#0FA47F',
    icon: 'baizhi',
    websiteUrl: 'https://baizhi.cloud',
    credentialKind: CredentialKind.Cookie,
    credentialRequiredFragment: 'baizhi_session',
    checkinUrl: 'https://baizhi.cloud/console/apps',
    // Reason: 这里存的是浏览器 Cookie，不是 API Key，不能进聊天服务商列表。
    chatCapable: false,
  },
];

export const MIMO_THINKING_MODELS: string[] = [
  'mimo-v2.6-flash',
  'mimo-v2.6-pro',
  'mimo-v2.6-pro-ultraspeed',
  'mimo-v2.5-pro',
  'mimo-v2.5'
];

export const KIMI_THINKING_MODELS: string[] = [
  'kimi-k3',
  'kimi-k2.7-code',
  'kimi-k2.7-code-highspeed',
  'kimi-k2.6'
];

/**
 * 判断指定服务商及模型是否支持深度思考模式
 */
export function isThinkingSupported(providerId: string, modelId?: string): boolean {
  if (providerId === 'deepseek') {
    return true;
  }
  if (providerId === 'mimo') {
    if (!modelId || modelId.length === 0 || modelId === '选择模型') {
      return true;
    }
    const lower: string = modelId.toLowerCase().trim();
    let i: number = 0;
    while (i < MIMO_THINKING_MODELS.length) {
      if (lower === MIMO_THINKING_MODELS[i] || lower.includes(MIMO_THINKING_MODELS[i])) {
        return true;
      }
      i += 1;
    }
    return lower.includes('mimo-v2.6') || lower.includes('mimo-v2.5');
  }
  if (providerId === 'kimi') {
    if (!modelId || modelId.length === 0 || modelId === '选择模型') {
      return true;
    }
    const lower: string = modelId.toLowerCase().trim();
    let i: number = 0;
    while (i < KIMI_THINKING_MODELS.length) {
      if (lower === KIMI_THINKING_MODELS[i] || lower.includes(KIMI_THINKING_MODELS[i])) {
        return true;
      }
      i += 1;
    }
    return lower.includes('k3') || lower.includes('k2.7') || lower.includes('k2.6');
  }
  const def: ProviderDefinition | undefined = findProvider(providerId);
  return def !== undefined && def.supportsThinking === true;
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

/**
 * 仅返回可参与对话的服务商（ChatView 用）。
 * Business Rule: 余额专用供应商（chatCapable=false）不得出现在聊天服务商列表，
 *   否则会把余额凭据当 API Key 发往对话接口。
 */
export function chatProviders(): ProviderDefinition[] {
  const out: ProviderDefinition[] = [];
  let i: number = 0;
  while (i < PROVIDERS.length) {
    if (PROVIDERS[i].chatCapable !== false) {
      out.push(PROVIDERS[i]);
    }
    i += 1;
  }
  return out;
}

export function categoryLabel(cat: ProviderCategory): string {
  // 注册表当前只有「国内官方」一类；将来引入聚合平台时在此按 cat 分支扩展。
  if (cat === ProviderCategory.CnOfficial) {
    return '国内官方';
  }
  return '其他';
}
