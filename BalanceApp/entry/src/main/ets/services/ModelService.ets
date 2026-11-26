/*
 * ModelService.ets
 *
 * 统一模型端点与模型拉取服务：应用只支持 DeepSeek。
 * - DeepSeek: https://api.deepseek.com/models
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ModelInfo } from '../models/ChatModels';
import { findProvider, ProviderDefinition } from './ProviderRegistry';

const DOMAIN = 0x0000;
const TAG = 'ModelService';
const TIMEOUT_MS = 10000;

export class ModelService {
  /**
   * 实时获取指定供应商的模型列表
   */
  public static async fetchModels(providerId: string, apiKey: string): Promise<ModelInfo[]> {
    const def: ProviderDefinition | undefined = findProvider(providerId);
    if (def === undefined || apiKey.trim().length === 0) {
      return [];
    }

    const candidateUrls: string[] = ModelService.buildCandidates(def.baseUrl);
    let i: number = 0;
    while (i < candidateUrls.length) {
      const targetUrl: string = candidateUrls[i];
      try {
        const fetchedIds: string[] = await ModelService.requestModels(targetUrl, apiKey);
        if (fetchedIds.length > 0) {
          hilog.info(DOMAIN, TAG, 'Fetched %{public}d models from %{public}s', fetchedIds.length, targetUrl);
          return ModelService.toModelInfos(fetchedIds);
        }
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to fetch models from %{public}s: %{public}s', targetUrl, String(err));
      }
      i += 1;
    }

    // 官方已于 2026-07-24 下线 deepseek-chat / deepseek-reasoner（见 V4 预览版公告），
    // 现行模型为 deepseek-flash 与 deepseek-v4-pro；联网服务端工具也只在这两个模型下可用。
    return ModelService.toModelInfos([
      'deepseek-flash',
      'deepseek-v4-pro'
    ]);
  }

  /**
   * 根据官方标准构建候选端点：
   * /models 与 /v1/models
   */
  private static buildCandidates(rawBaseUrl: string): string[] {
    let trimmed: string = rawBaseUrl.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.length === 0) {
      return [];
    }

    const list: string[] = [];
    if (trimmed.endsWith('/v1')) {
      list.push(`${trimmed}/models`);
    } else {
      list.push(`${trimmed}/models`);
      list.push(`${trimmed}/v1/models`);
    }
    return list;
  }

  /**
   * 真实发起 GET /models 请求
   */
  private static async requestModels(url: string, apiKey: string): Promise<string[]> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const headerMap: Record<string, string> = {
        'Authorization': `Bearer ${apiKey.trim()}`,
        'Accept': 'application/json'
      };

      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: headerMap,
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS
      });

      if (resp.responseCode !== 200) {
        return [];
      }

      let parsed: ESObject;
      if (typeof resp.result === 'string') {
        parsed = JSON.parse(resp.result as string) as ESObject;
      } else {
        parsed = resp.result as ESObject;
      }

      if (parsed === null || typeof parsed !== 'object') {
        return [];
      }

      const rootRec: Record<string, ESObject> = parsed as Record<string, ESObject>;
      const rawData: ESObject = rootRec['data'];
      if (!Array.isArray(rawData)) {
        return [];
      }

      const arr: ESObject[] = rawData as ESObject[];
      const result: string[] = [];
      let i: number = 0;
      while (i < arr.length) {
        const item: ESObject = arr[i];
        if (item !== null && typeof item === 'object') {
          const itemRec: Record<string, ESObject> = item as Record<string, ESObject>;
          const idVal: ESObject = itemRec['id'];
          if (typeof idVal === 'string' && (idVal as string).trim().length > 0) {
            result.push((idVal as string).trim());
          }
        }
        i += 1;
      }
      return result;
    } finally {
      req.destroy();
    }
  }

  private static toModelInfos(ids: string[]): ModelInfo[] {
    const res: ModelInfo[] = [];
    let i: number = 0;
    while (i < ids.length) {
      const id: string = ids[i];
      const info: ModelInfo = {
        id: id,
        name: id
      };
      res.push(info);
      i += 1;
    }
    return res;
  }
}
