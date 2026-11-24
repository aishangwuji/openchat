/*
 * BalanceService.ets
 *
 * 统一余额查询服务 —— 对齐智额 `providers/adapters/balance_query_service.dart` +
 * `bearer_balance_adapter.dart` 的实现形式（酒馆/SillyTavern 相关除外）：
 * 按 ProviderDefinition.balanceType 路由（Bearer / CookieSession），
 * 请求通道与响应解析各抽一层，由 BalanceQueryConfig 做通用解析。
 *
 * Reason: 与参考实现保持一致的错误通道语义：
 *   - throw Error = 瞬时传输失败（网络不可达/超时），调用方可重试并保留上次成功值；
 *   - 返回 { success:false } = 确定性失败（空 key/未知供应商/鉴权/非 2xx/非法 JSON）。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ProviderDefinition, BalanceQueryConfig, BalanceInfo, CreditDetail,
  BalanceQueryType, CredentialKind, findProvider,
} from './ProviderRegistry';

const DOMAIN = 0x0000;
const TAG = 'BalanceService';
const TIMEOUT_MS = 15000;
/** Cookie 类供应商的兜底 UA（与注册表配置一致，防 WAF 按 UA 拦截）。 */
const DEFAULT_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:160.0) Gecko/20100101 Firefox/160.0';

export interface ProviderBalanceResult {
  success: boolean;
  info?: BalanceInfo;
  error?: string;
}

function toNumber(v: ESObject | null | undefined): number {
  if (v === null || v === undefined) {
    return 0.0;
  }
  if (typeof v === 'number') {
    const n: number = v as number;
    return Number.isFinite(n) ? n : 0.0;
  }
  if (typeof v === 'string') {
    const s: string = v as string;
    const n: number = Number(s.trim());
    return Number.isFinite(n) ? n : 0.0;
  }
  return 0.0;
}

function toText(v: ESObject | null | undefined, fallback: string): string {
  if (typeof v === 'string') {
    return v as string;
  }
  return fallback;
}

function fieldOf(obj: ESObject | null | undefined, field: string | undefined): ESObject | null {
  if (obj === null || obj === undefined || field === undefined) {
    return null;
  }
  if (typeof obj !== 'object') {
    return null;
  }
  const rec: Record<string, ESObject> = obj as Record<string, ESObject>;
  const v: ESObject = rec[field];
  if (v === null || v === undefined) {
    return null;
  }
  return v;
}

/** Reason: 对齐智额 responsePath 点分导航（如 'data'、'balance_infos'）。 */
function navigatePath(root: ESObject, path: string | undefined): ESObject | null {
  if (path === undefined) {
    return root;
  }
  let cur: ESObject | null = root;
  const keys: string[] = path.split('.');
  let i: number = 0;
  while (i < keys.length) {
    cur = fieldOf(cur, keys[i]);
    if (cur === null) {
      return null;
    }
    i += 1;
  }
  return cur;
}

/** Reason: 对齐智额 _buildUrl（绝对 URL 直用，否则拼接到 baseUrl 后）。 */
function buildUrl(baseUrl: string, endpoint: string): string {
  if (endpoint.startsWith('http')) {
    return endpoint;
  }
  if (endpoint.length === 0) {
    return baseUrl;
  }
  let base: string = baseUrl;
  if (base.endsWith('/')) {
    base = base.slice(0, base.length - 1);
  }
  return `${base}${endpoint}`;
}

/**
 * 边界归一化：去掉粘贴时混入的 `Cookie:` 前缀与换行。
 * Reason: 用户常从 DevTools 整行复制「Cookie: a=b; c=d」，直接当请求头的值会发脏数据。
 */
function normalizeCredential(raw: string, kind: CredentialKind): string {
  if (kind !== CredentialKind.Cookie) {
    return raw.trim();
  }
  const flat: string = raw.replace(/[\r\n]+/g, ' ').trim();
  if (flat.toLowerCase().startsWith('cookie:')) {
    return flat.substring(7).trim();
  }
  return flat;
}

function bearerHeaders(apiKey: string, useBearerPrefix: boolean): Record<string, string> {
  const authValue: string = useBearerPrefix ? `Bearer ${apiKey}` : apiKey;
  return {
    'Authorization': authValue,
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };
}

function cookieHeaders(cookie: string, userAgent: string): Record<string, string> {
  // Reason: 百智云按浏览器指纹 + Cookie 做 WAF 校验，UA 必须与取 Cookie 的浏览器一致。
  return {
    'Cookie': cookie,
    'User-Agent': userAgent,
    'Accept': '*/*',
  };
}

/**
 * 统一 GET 文本通道：把网络异常/鉴权失败/非 2xx 收敛成三种错误通道，
 * 供 Bearer 与 Cookie 两种引擎复用（解析逻辑不重复）。
 */
async function requestText(def: ProviderDefinition, url: string, headers: Record<string, string>): Promise<string> {
  const req: http.HttpRequest = http.createHttp();
  let status: number = 0;
  let bodyText: string = '';
  try {
    const resp: http.HttpResponse = await req.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      readTimeout: TIMEOUT_MS,
      connectTimeout: TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING,
    });
    status = resp.responseCode;
    if (typeof resp.result === 'string') {
      bodyText = resp.result as string;
    } else {
      bodyText = JSON.stringify(resp.result);
    }
  } catch (err) {
    const msg: string = err instanceof Error ? err.message : 'request failed';
    hilog.error(DOMAIN, TAG, 'Network error, provider=%{public}s detail=%{public}s', def.id, msg);
    throw new Error(`Network error: ${msg}`);
  } finally {
    req.destroy();
  }

  if (status === 401 || status === 403) {
    throw new AuthFailedError(status);
  }
  hilog.info(DOMAIN, TAG, 'Response received, provider=%{public}s status=%{public}d len=%{public}d',
    def.id, status, bodyText.length);
  if (status < 200 || status >= 300) {
    throw new DeterministicError(`API error (HTTP ${status}): ${bodyText.slice(0, 300)}`);
  }
  return bodyText;
}

/**
 * 通用响应解析引擎 —— 对齐智额 BearerBalanceAdapter：
 * responsePath 导航 → 对象字段/数组求和/纯数字三种形态 → 换算因子 → used 推导 → 积分明细。
 */
function parseBody(def: ProviderDefinition, bodyText: string): BalanceInfo {
  const config: BalanceQueryConfig = def.balanceConfig;
  let root: ESObject | null = null;
  try {
    const parsed: ESObject = JSON.parse(bodyText);
    root = parsed;
  } catch (err) {
    root = null;
  }
  if (root === null || typeof root !== 'object') {
    throw new DeterministicError('Failed to parse response');
  }

  // 业务成功码校验（如 Kimi code!=0 / 百智云会话失效 code!=0；未配置则跳过，避免误伤它家）。
  if (config.successCodeField !== undefined && config.successCodeValue !== undefined) {
    const codeVal: ESObject | null = fieldOf(root, config.successCodeField as string);
    let ok: boolean = false;
    if (typeof codeVal === 'number') {
      ok = (codeVal as number) === (config.successCodeValue as number);
    } else if (typeof codeVal === 'string') {
      ok = (codeVal as string) === String(config.successCodeValue as number);
    }
    if (!ok) {
      // Reason: Cookie 类失败几乎都是会话过期，直接给可执行的提示，别只抛 JSON 片段。
      if (def.balanceType === BalanceQueryType.CookieSession) {
        throw new DeterministicError('登录态失效（Cookie 无效或已过期），请重新从浏览器复制');
      }
      throw new DeterministicError(`API error (business code): ${bodyText.slice(0, 300)}`);
    }
  }

  const target: ESObject | null = navigatePath(root, config.responsePath);
  let available: number = 0.0;
  let total: number = 0.0;
  let used: number = 0.0;
  let currency: string = config.defaultCurrency !== undefined ? (config.defaultCurrency as string) : 'CNY';

  if (target !== null && Array.isArray(target)) {
    // 数组响应（DeepSeek balance_infos）：逐项求和。
    const arr: ESObject[] = target as ESObject[];
    const availKey: string = config.availableField !== undefined ? (config.availableField as string) : 'total_balance';
    const currKey: string = config.currencyField !== undefined ? (config.currencyField as string) : 'currency';
    let i: number = 0;
    while (i < arr.length) {
      const item: ESObject | null = arr[i];
      if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
        const b: number = toNumber(fieldOf(item, availKey));
        available += b;
        total += b;
        const c: string = toText(fieldOf(item, currKey), '');
        if (c.length > 0) {
          currency = c;
        }
      }
      i += 1;
    }
  } else if (target !== null && typeof target === 'object') {
    available = toNumber(fieldOf(target, config.availableField));
    total = toNumber(fieldOf(target, config.totalField));
    used = toNumber(fieldOf(target, config.usedField));
    if (config.currencyField !== undefined) {
      currency = toText(fieldOf(target, config.currencyField), currency);
    }
  } else if (typeof target === 'number') {
    available = target as number;
    total = available;
  }

  const multiplier: number = config.amountMultiplier !== undefined ? (config.amountMultiplier as number) : 1.0;
  available *= multiplier;
  total *= multiplier;
  used *= multiplier;

  // 对齐智额：used 缺省且 total > available 时推导 used。
  if (config.usedField === undefined && total > 0 && used === 0 && total > available) {
    used = total - available;
  }
  // 偏离说明（Reason）：智额引擎在 availableField 缺省时（仅给 total/used 的厂商）会算出
  // available=0；此处补一条对称推导 available = total - used，保证卡片可用余额正确。
  if (config.availableField === undefined && total > 0 && available === 0 && used > 0) {
    available = total - used;
  }

  // 积分明细（百智云钱包）：与主余额共用同一换算因子，缺字段按 0 处理。
  let credit: CreditDetail | undefined = undefined;
  if (config.temporaryCreditField !== undefined && target !== null &&
    typeof target === 'object' && !Array.isArray(target)) {
    const claimedVal: ESObject | null =
      config.dailyClaimedField !== undefined ? fieldOf(target, config.dailyClaimedField as string) : null;
    credit = {
      temporary: toNumber(fieldOf(target, config.temporaryCreditField as string)) * multiplier,
      permanent: toNumber(fieldOf(target, config.permanentCreditField)) * multiplier,
      frozen: toNumber(fieldOf(target, config.frozenCreditField)) * multiplier,
      dailyClaimed: claimedVal === true,
    };
  }

  const finalTotal: number = total > 0 ? total : available + used;
  const info: BalanceInfo = {
    providerId: def.id,
    total: finalTotal,
    used: used,
    available: available,
    currency: currency,
    updatedAt: new Date().toLocaleString(),
    credit: credit,
  };
  return info;
}

/** Bearer 引擎：Authorization 头 + 通用解析。 */
async function queryBearer(def: ProviderDefinition, apiKey: string): Promise<BalanceInfo> {
  const config: BalanceQueryConfig = def.balanceConfig;
  const usePrefix: boolean = config.useBearerPrefix === undefined || (config.useBearerPrefix as boolean);
  const url: string = buildUrl(def.baseUrl, config.endpoint);
  const bodyText: string = await requestText(def, url, bearerHeaders(apiKey, usePrefix));
  return parseBody(def, bodyText);
}

/** Cookie 引擎：Cookie 头 + 浏览器 UA + 通用解析（百智云钱包）。 */
async function queryCookieSession(def: ProviderDefinition, cookie: string): Promise<BalanceInfo> {
  const config: BalanceQueryConfig = def.balanceConfig;
  const userAgent: string = config.userAgent !== undefined ? (config.userAgent as string) : DEFAULT_UA;
  const url: string = buildUrl(def.baseUrl, config.endpoint);
  const bodyText: string = await requestText(def, url, cookieHeaders(cookie, userAgent));
  return parseBody(def, bodyText);
}

class AuthFailedError extends Error {
  status: number = 0;
  constructor(status: number) {
    super(`Authentication failed (HTTP ${status})`);
    this.status = status;
  }
}

class DeterministicError extends Error {
  constructor(msg: string) {
    super(msg);
  }
}

/**
 * 查询公开入口：按供应商 id 路由到 Bearer / Cookie 引擎。
 * Business Rule: 边界处先校验（未知 id / 空凭证 / Cookie 缺会话标识），失败直接返回，不进网络层。
 */
export async function fetchProviderBalance(defId: string, credential: string): Promise<ProviderBalanceResult> {
  const found: ProviderDefinition | undefined = findProvider(defId);
  if (found === undefined) {
    const r: ProviderBalanceResult = { success: false, info: undefined, error: 'Unknown provider' };
    return r;
  }
  const def: ProviderDefinition = found as ProviderDefinition;
  const kind: CredentialKind = def.credentialKind !== undefined
    ? (def.credentialKind as CredentialKind) : CredentialKind.Bearer;
  const cred: string = normalizeCredential(credential, kind);
  if (cred.length === 0) {
    const emptyMsg: string = kind === CredentialKind.Cookie
      ? 'Cookie 为空，请从浏览器复制完整 Cookie' : 'API key is empty';
    const r: ProviderBalanceResult = { success: false, info: undefined, error: emptyMsg };
    return r;
  }
  if (kind === CredentialKind.Cookie) {
    const fragment: string | undefined = def.credentialRequiredFragment;
    if (fragment !== undefined && !cred.includes(fragment as string)) {
      const r: ProviderBalanceResult = {
        success: false, info: undefined,
        error: `Cookie 缺少 ${fragment}，请确认复制的是登录后的完整 Cookie`,
      };
      return r;
    }
  }
  try {
    let info: BalanceInfo;
    if (def.balanceType === BalanceQueryType.CookieSession) {
      info = await queryCookieSession(def, cred);
    } else {
      info = await queryBearer(def, cred);
    }
    const ok: ProviderBalanceResult = { success: true, info: info, error: undefined };
    return ok;
  } catch (err) {
    if (err instanceof AuthFailedError) {
      const e: AuthFailedError = err as AuthFailedError;
      const r: ProviderBalanceResult = { success: false, info: undefined, error: e.message };
      return r;
    }
    if (err instanceof DeterministicError) {
      const e: DeterministicError = err as DeterministicError;
      const r: ProviderBalanceResult = { success: false, info: undefined, error: e.message };
      return r;
    }
    // 瞬时传输失败 → throw，调用方按可重试处理。
    // Reason: ArkTS 仅允许 throw Error 类型，透传未知捕获值需先包一层。
    if (err instanceof Error) {
      throw err;
    }
    throw new Error('Network error: request failed');
  }
}
