/*
 * BalanceService.ets
 *
 * 统一余额查询服务：Bearer 引擎 + 通用解析，应用只支持 DeepSeek。
 *
 * Reason: 错误通道语义：
 *   - throw Error = 瞬时传输失败（网络不可达/超时），调用方可重试并保留上次成功值；
 *   - 返回 { success:false } = 确定性失败（空 key/未知供应商/鉴权/非 2xx/非法 JSON）。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ProviderDefinition, BalanceQueryConfig, BalanceInfo, findProvider,
} from './ProviderRegistry';

const DOMAIN = 0x0000;
const TAG = 'BalanceService';
const TIMEOUT_MS = 15000;

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

function bearerHeaders(apiKey: string): Record<string, string> {
  return {
    'Authorization': `Bearer ${apiKey}`,
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };
}

/**
 * 统一 GET 文本通道：把网络异常/鉴权失败/非 2xx 收敛成三种错误通道。
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

  // 对齐智额：used 缺省且 total > available 时推导 used。
  if (config.usedField === undefined && total > 0 && used === 0 && total > available) {
    used = total - available;
  }
  // 偏离说明（Reason）：智额引擎在 availableField 缺省时（仅给 total/used 的厂商）会算出
  // available=0；此处补一条对称推导 available = total - used，保证卡片可用余额正确。
  if (config.availableField === undefined && total > 0 && available === 0 && used > 0) {
    available = total - used;
  }

  const finalTotal: number = total > 0 ? total : available + used;
  const info: BalanceInfo = {
    providerId: def.id,
    total: finalTotal,
    used: used,
    available: available,
    currency: currency,
    updatedAt: new Date().toLocaleString(),
  };
  return info;
}

/** Bearer 引擎：Authorization 头 + 通用解析。 */
async function queryBearer(def: ProviderDefinition, apiKey: string): Promise<BalanceInfo> {
  const config: BalanceQueryConfig = def.balanceConfig;
  const url: string = buildUrl(def.baseUrl, config.endpoint);
  const bodyText: string = await requestText(def, url, bearerHeaders(apiKey));
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
 * 查询公开入口：边界处先校验（未知 id / 空凭证），失败直接返回，不进网络层。
 */
export async function fetchProviderBalance(defId: string, credential: string): Promise<ProviderBalanceResult> {
  const found: ProviderDefinition | undefined = findProvider(defId);
  if (found === undefined) {
    const r: ProviderBalanceResult = { success: false, info: undefined, error: 'Unknown provider' };
    return r;
  }
  const def: ProviderDefinition = found as ProviderDefinition;
  const cred: string = credential.trim();
  if (cred.length === 0) {
    const r: ProviderBalanceResult = { success: false, info: undefined, error: 'API key is empty' };
    return r;
  }
  try {
    const info: BalanceInfo = await queryBearer(def, cred);
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
