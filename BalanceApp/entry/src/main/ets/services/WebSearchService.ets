/*
 * WebSearchService.ets
 *
 * DeepSeek 服务端联网工具（deepseek_web_search）的纯逻辑层 —— 与 UI 解耦，可独立审查：
 * 1. buildToolDeclaration：请求体 tools 声明；声明后 temperature/top_p 等由服务端忽略，
 *    搜索与抓取全在服务端完成，客户端只负责展示（不计费，仅计模型 token）。
 * 2. parseToolEvent：解析流式 choice.server_tool_event（call_started / call_completed），
 *    只关心 search / deep_search / image_search / deep_image_search 四类 kind；
 *    read_link 的来源在 signature 里、结构不同，本期不展示（见 techdebt/TD-002）。
 * 3. parseCitations：解析末块 delta.annotations（url_citation），拿到引用区间（Unicode 码点）
 *    与只出现在引用里的来源，供 MarkdownService.injectCitations 在正文插可点角标。
 * 4. mergeSources：按 url 去重合并，先到先得，缺字段用后到的补（展示字段以搜索结果为准）。
 *
 * 严格遵守 ArkTS 规范：无 any/unknown，无解构，捕获异常转为 Error 类型。
 */

import { CitationRange, SearchSource } from '../models/ChatModels';

/** 单轮会话最多保留的来源数：一次深度搜索可能返回几十条，超出部分不进卡片列表。 */
const MAX_SOURCES = 24;
const MAX_TITLE_CHARS = 300;
const MAX_SNIPPET_CHARS = 500;
/** 过程提示里关键词的展示长度上限（超出截断加省略号，避免顶掉气泡宽度）。 */
const MAX_QUERY_DISPLAY_CHARS = 24;
/**
 * 单条回复留存的服务端工具调用原文上限（字符）。
 * Business Rule: 阅读链接的网页正文加密在 signature 里，体积可能有几十 KB；
 *   超限只丢这一条的原文（多轮少了这页上下文），避免整份会话 JSON 撑爆本地存储。
 */
export const TOOL_CALLS_MAX_CHARS = 200000;

export type SearchPhase = 'started' | 'completed';

export interface SearchProgress {
  /** started=调用发起（带 queries/action）；completed=调用结束（带 sources/失败标记）。 */
  phase: SearchPhase;
  /** search / deep_search / image_search / deep_image_search。 */
  kind: string;
  /** 调用动作：search / open_page / find_in_page（深搜时后两者不带 queries）。 */
  action: string;
  queries: string[];
  sources: SearchSource[];
  failed: boolean;
}

export class WebSearchService {
  /**
   * Business Rule: 服务端联网工具目前只在 DeepSeek 官方接口可用；其余服务商声明会 400，
   *   故能力开关按 providerId 收口，不按模型收口（实测 deepseek-flash 与 deepseek-v4-pro 均可用）。
   */
  public static isSupported(providerId: string): boolean {
    return providerId === 'deepseek';
  }

  /** 请求体 tools 声明（Chat Completions 协议只认 type 字段，name 可省）。 */
  public static buildToolDeclaration(): Record<string, string>[] {
    const item: Record<string, string> = { 'type': 'deepseek_web_search' };
    const tools: Record<string, string>[] = [item];
    return tools;
  }

  /**
   * 阅读链接工具声明（deepseek_read_url）。
   * Business Rule: 开思考且同时声明了搜索时，服务端走深度思考搜索、本轮不单独读链接；
   *   只有关思考或未声明搜索时才会读用户消息里的 URL（官方《阅读链接》）。
   */
  public static buildReadUrlDeclaration(): Record<string, string>[] {
    const item: Record<string, string> = { 'type': 'deepseek_read_url' };
    const tools: Record<string, string>[] = [item];
    return tools;
  }

  /**
   * 解析 server_tool_event；非本次搜索能力的调用（如 step_reasoning_done）返回 undefined。
   * Reason: 事件挂在 choice 上与 delta 并列、一次 chunk 最多一个，调用方按到达顺序处理即可。
   */
  public static parseToolEvent(raw: ESObject): SearchProgress | undefined {
    if (raw === null || typeof raw !== 'object') {
      return undefined;
    }
    const rec: Record<string, ESObject> = raw as Record<string, ESObject>;
    const typeVal: ESObject = rec['type'];
    if (typeof typeVal !== 'string') {
      return undefined;
    }
    const typeStr: string = typeVal as string;
    if (typeStr !== 'call_started' && typeStr !== 'call_completed') {
      return undefined;
    }

    const callVal: ESObject = rec['call'];
    if (callVal === null || typeof callVal !== 'object') {
      return undefined;
    }
    const callRec: Record<string, ESObject> = callVal as Record<string, ESObject>;
    const kindVal: ESObject = callRec['kind'];
    const kind: string = typeof kindVal === 'string' ? kindVal as string : '';
    // Business Rule: 实测 call_started 的 call 带 kind，call_completed 的 call 只有
    //   index/id/status/sources（不带 kind），故 kind 缺失一律放行，只有明确的非搜索能力才丢弃。
    if (kind.length > 0 && kind !== 'search' && kind !== 'deep_search' &&
      kind !== 'read_link' && kind !== 'image_search' &&
      kind !== 'deep_image_search') {
      return undefined;
    }

    const queries: string[] = [];
    let actionType: string = '';
    const actionVal: ESObject = callRec['action'];
    if (actionVal !== null && typeof actionVal === 'object') {
      const actionRec: Record<string, ESObject> = actionVal as Record<string, ESObject>;
      const actionTypeVal: ESObject = actionRec['type'];
      if (typeof actionTypeVal === 'string') {
        actionType = actionTypeVal as string;
      }
      const qVal: ESObject = actionRec['queries'];
      if (Array.isArray(qVal)) {
        const qArr: ESObject[] = qVal as ESObject[];
        let qi: number = 0;
        while (qi < qArr.length) {
          if (typeof qArr[qi] === 'string' && (qArr[qi] as string).trim().length > 0) {
            queries.push((qArr[qi] as string).trim());
          }
          qi += 1;
        }
      }
    }

    const sources: SearchSource[] = WebSearchService.parseSourceArray(callRec['sources']);
    // 打开网页 / 阅读链接的结果：call.page 带 url/title/published_at（正文在 signature 里）。
    const pageVal: ESObject = callRec['page'];
    if (pageVal !== null && typeof pageVal === 'object') {
      const pageRec: Record<string, ESObject> = pageVal as Record<string, ESObject>;
      const pageUrlVal: ESObject = pageRec['url'];
      if (typeof pageUrlVal === 'string') {
        const pageUrl: string = (pageUrlVal as string).trim();
        if (WebSearchService.isHttpUrl(pageUrl)) {
          const pageTitle: string = WebSearchService.stringField(pageRec, 'title', MAX_TITLE_CHARS);
          const pageSource: SearchSource = {
            url: pageUrl,
            title: pageTitle.length > 0 ? pageTitle : pageUrl
          };
          const pagePublished: string = WebSearchService.stringField(pageRec, 'published_at', 64);
          if (pagePublished.length > 0) {
            pageSource.publishedAt = pagePublished;
          }
          sources.push(pageSource);
        }
      }
    }
    const statusVal: ESObject = callRec['status'];
    const failed: boolean = typeStr === 'call_completed' && statusVal === 'failed';

    const progress: SearchProgress = {
      phase: typeStr === 'call_started' ? 'started' : 'completed',
      kind: kind,
      action: actionType,
      queries: queries,
      sources: sources,
      failed: failed
    };
    return progress;
  }

  /**
   * 解析末块 delta.annotations：Chat Completions 的正文没有引用角标，
   *   引用范围（start_index/end_index，Unicode 码点）与来源都在这里一次性下发。
   * Business Rule: 只收 http/https 来源与合法区间（start>=0 且 end>start），
   *   同一 URL 可对应多个区间，故按区间逐条保留，不做 URL 去重。
   */
  public static parseCitations(delta: ESObject): CitationRange[] {
    const out: CitationRange[] = [];
    if (delta === null || typeof delta !== 'object') {
      return out;
    }
    const rec: Record<string, ESObject> = delta as Record<string, ESObject>;
    const annVal: ESObject = rec['annotations'];
    if (!Array.isArray(annVal)) {
      return out;
    }
    const arr: ESObject[] = annVal as ESObject[];
    let i: number = 0;
    while (i < arr.length) {
      const item: ESObject = arr[i];
      i += 1;
      if (item === null || typeof item !== 'object') {
        continue;
      }
      const itemRec: Record<string, ESObject> = item as Record<string, ESObject>;
      if (itemRec['type'] !== 'url_citation') {
        continue;
      }
      const citeVal: ESObject = itemRec['url_citation'];
      if (citeVal === null || typeof citeVal !== 'object') {
        continue;
      }
      const citeRec: Record<string, ESObject> = citeVal as Record<string, ESObject>;
      const urlVal: ESObject = citeRec['url'];
      if (typeof urlVal !== 'string') {
        continue;
      }
      const url: string = (urlVal as string).trim();
      if (!WebSearchService.isHttpUrl(url)) {
        continue;
      }
      const startVal: ESObject = citeRec['start_index'];
      const endVal: ESObject = citeRec['end_index'];
      if (typeof startVal !== 'number' || typeof endVal !== 'number') {
        continue;
      }
      const start: number = Math.floor(startVal as number);
      const end: number = Math.floor(endVal as number);
      if (start < 0 || end <= start) {
        continue;
      }
      const titleVal: ESObject = citeRec['title'];
      const title: string = typeof titleVal === 'string' ?
        WebSearchService.clamp((titleVal as string).trim(), MAX_TITLE_CHARS) : '';
      const cite: CitationRange = { url: url, title: title, start: start, end: end };
      out.push(cite);
    }
    return out;
  }

  /**
   * 按 url 去重合并：已有条目保留原顺序与展示字段，新条目缺失的字段由后到者补全。
   * Reason: 搜索结果块带 snippet/site_name，引用块只有 url/title；两者都可能先到，
   *   以「先到者为准、后到者只补空」避免标题被更短的引用标题覆盖。
   */
  public static mergeSources(base: SearchSource[] | undefined, incoming: SearchSource[]): SearchSource[] {
    const out: SearchSource[] = [];
    if (base !== undefined) {
      let bi: number = 0;
      while (bi < base.length) {
        out.push(base[bi]);
        bi += 1;
      }
    }
    let i: number = 0;
    while (i < incoming.length) {
      const src: SearchSource = incoming[i];
      i += 1;
      const at: number = WebSearchService.indexOfUrl(out, src.url);
      if (at >= 0) {
        WebSearchService.fillMissing(out[at], src);
      } else if (out.length < MAX_SOURCES) {
        out.push(src);
      }
    }
    return out;
  }

  /** 检索中提示：带首个关键词与关键词个数，空 query（图片搜索）走通用文案。 */
  public static searchingLabel(queries: string[]): string {
    if (queries.length === 0) {
      return '正在联网搜索…';
    }
    const first: string = WebSearchService.clamp(queries[0], MAX_QUERY_DISPLAY_CHARS);
    if (queries.length === 1) {
      return `正在联网搜索「${first}」…`;
    }
    return `正在联网搜索「${first}」等 ${queries.length} 个关键词…`;
  }

  /**
   * 调用发起提示：按 action 区分搜索/打开网页/页内查找。
   * Business Rule: 深度思考搜索一轮会连续发起多步调用，若统一显示「正在搜索」，
   *   用户会误以为卡在搜索；这里按动作给出对应文案。
   */
  public static startedLabel(progress: SearchProgress): string {
    if (progress.action === 'read_link') {
      return '正在阅读链接…';
    }
    if (progress.action === 'open_page') {
      return '正在阅读网页…';
    }
    if (progress.action === 'find_in_page') {
      return '正在网页内查找…';
    }
    if (progress.kind === 'image_search' || progress.kind === 'deep_image_search') {
      return '正在按图片搜索…';
    }
    return WebSearchService.searchingLabel(progress.queries);
  }

  /** 检索结束、正文未出：给出已拿到的来源数，避免界面停在「思考中」。 */
  public static searchedLabel(count: number): string {
    if (count <= 0) {
      return '搜索已完成，正在整理答案…';
    }
    return `已检索 ${count} 个来源，正在整理答案…`;
  }

  /** 来源站点名：优先服务端 site_name，缺失回退主机名（去 www.），再回退 url。 */
  public static sourceSite(src: SearchSource): string {
    if (src.siteName !== undefined && src.siteName.trim().length > 0) {
      return src.siteName.trim();
    }
    const host: string = WebSearchService.hostOf(src.url);
    return host.length > 0 ? host : src.url;
  }

  /**
   * 末块 delta.server_tool_calls → 本地留存原文；结构不合法或超限返回 ''。
   * Business Rule: 阅读链接的网页正文加密在 signature 里，多轮必须原样回传整段，
   *   所以不重拼结构、只做校验后存原文；校验不过按「没有工具调用」处理，请求照发。
   */
  public static serializeServerToolCalls(raw: ESObject): string {
    if (!Array.isArray(raw)) {
      return '';
    }
    // Business Rule: 只有阅读链接的 signature 需要回传——深度思考搜索打开的网页
    //   没有 signature，也不进入后续轮次上下文（官方《多轮对话》），留着只会在
    //   会话 JSON 里堆几十 KB（实测一次深搜 18KB）。
    const steps: ESObject[] = raw as ESObject[];
    const pruned: ESObject[] = [];
    let i: number = 0;
    while (i < steps.length) {
      const step: ESObject = steps[i];
      i += 1;
      if (step === null || typeof step !== 'object' || Array.isArray(step)) {
        continue;
      }
      const stepRec: Record<string, ESObject> = step as Record<string, ESObject>;
      const callsVal: ESObject = stepRec['calls'];
      if (!Array.isArray(callsVal)) {
        continue;
      }
      const calls: ESObject[] = callsVal as ESObject[];
      const kept: ESObject[] = [];
      let j: number = 0;
      while (j < calls.length) {
        const call: ESObject = calls[j];
        j += 1;
        if (call === null || typeof call !== 'object' || Array.isArray(call)) {
          continue;
        }
        const callRec: Record<string, ESObject> = call as Record<string, ESObject>;
        const sig: ESObject = callRec['signature'];
        if (typeof sig === 'string' && (sig as string).length > 0) {
          kept.push(call);
        }
      }
      if (kept.length === 0) {
        continue;
      }
      const prunedStep: Record<string, ESObject> = { 'calls': kept as ESObject };
      if (typeof stepRec['index'] === 'number') {
        prunedStep['index'] = stepRec['index'];
      }
      if (typeof stepRec['reasoning_content'] === 'string') {
        prunedStep['reasoning_content'] = stepRec['reasoning_content'];
      }
      pruned.push(prunedStep as ESObject);
    }
    if (pruned.length === 0) {
      return '';
    }
    let json: string = '';
    try {
      json = JSON.stringify(pruned as ESObject);
    } catch (_e) {
      return '';
    }
    if (json.length === 0 || json.length > TOOL_CALLS_MAX_CHARS) {
      return '';
    }
    return WebSearchService.parseServerToolCalls(json) !== undefined ? json : '';
  }

  /** 校验并解析留存的工具调用原文（跨边界数据，不可信）；结构不符返回 undefined。 */
  public static parseServerToolCalls(rawJson: string): ESObject[] | undefined {
    if (rawJson.length === 0 || rawJson.length > TOOL_CALLS_MAX_CHARS) {
      return undefined;
    }
    let parsed: ESObject;
    try {
      parsed = JSON.parse(rawJson) as ESObject;
    } catch (_e) {
      return undefined;
    }
    if (!Array.isArray(parsed)) {
      return undefined;
    }
    const steps: ESObject[] = parsed as ESObject[];
    const out: ESObject[] = [];
    let i: number = 0;
    while (i < steps.length) {
      const step: ESObject = steps[i];
      i += 1;
      if (step === null || typeof step !== 'object' || Array.isArray(step)) {
        return undefined;
      }
      const stepRec: Record<string, ESObject> = step as Record<string, ESObject>;
      const callsVal: ESObject = stepRec['calls'];
      if (!Array.isArray(callsVal)) {
        return undefined;
      }
      const calls: ESObject[] = callsVal as ESObject[];
      let j: number = 0;
      while (j < calls.length) {
        const call: ESObject = calls[j];
        j += 1;
        if (call === null || typeof call !== 'object' || Array.isArray(call)) {
          return undefined;
        }
        const callRec: Record<string, ESObject> = call as Record<string, ESObject>;
        if (typeof callRec['kind'] !== 'string') {
          return undefined;
        }
        const action: ESObject = callRec['action'];
        if (action === null || typeof action !== 'object' || Array.isArray(action)) {
          return undefined;
        }
      }
      out.push(step);
    }
    return out.length > 0 ? out : undefined;
  }

  private static parseSourceArray(raw: ESObject): SearchSource[] {
    const out: SearchSource[] = [];
    if (!Array.isArray(raw)) {
      return out;
    }
    const arr: ESObject[] = raw as ESObject[];
    let i: number = 0;
    while (i < arr.length) {
      const item: ESObject = arr[i];
      i += 1;
      if (item === null || typeof item !== 'object') {
        continue;
      }
      const rec: Record<string, ESObject> = item as Record<string, ESObject>;
      const urlVal: ESObject = rec['url'];
      if (typeof urlVal !== 'string') {
        continue;
      }
      const url: string = (urlVal as string).trim();
      if (!WebSearchService.isHttpUrl(url)) {
        continue;
      }
      const src: SearchSource = {
        url: url,
        title: WebSearchService.stringField(rec, 'title', MAX_TITLE_CHARS)
      };
      const snippet: string = WebSearchService.stringField(rec, 'snippet', MAX_SNIPPET_CHARS);
      if (snippet.length > 0) {
        src.snippet = snippet;
      }
      const siteName: string = WebSearchService.stringField(rec, 'site_name', MAX_TITLE_CHARS);
      if (siteName.length > 0) {
        src.siteName = siteName;
      }
      const siteIcon: string = WebSearchService.stringField(rec, 'site_icon', MAX_TITLE_CHARS);
      if (siteIcon.length > 0 && WebSearchService.isHttpUrl(siteIcon)) {
        src.siteIcon = siteIcon;
      }
      const publishedAt: string = WebSearchService.stringField(rec, 'published_at', 64);
      if (publishedAt.length > 0) {
        src.publishedAt = publishedAt;
      }
      out.push(src);
    }
    return out;
  }

  private static fillMissing(target: SearchSource, extra: SearchSource): void {
    if (target.title.length === 0 && extra.title.length > 0) {
      target.title = extra.title;
    }
    if (target.snippet === undefined && extra.snippet !== undefined) {
      target.snippet = extra.snippet;
    }
    if (target.siteName === undefined && extra.siteName !== undefined) {
      target.siteName = extra.siteName;
    }
    if (target.siteIcon === undefined && extra.siteIcon !== undefined) {
      target.siteIcon = extra.siteIcon;
    }
    if (target.publishedAt === undefined && extra.publishedAt !== undefined) {
      target.publishedAt = extra.publishedAt;
    }
  }

  private static indexOfUrl(list: SearchSource[], url: string): number {
    let i: number = 0;
    while (i < list.length) {
      if (list[i].url === url) {
        return i;
      }
      i += 1;
    }
    return -1;
  }

  private static stringField(rec: Record<string, ESObject>, key: string, maxChars: number): string {
    const val: ESObject = rec[key];
    if (typeof val !== 'string') {
      return '';
    }
    return WebSearchService.clamp((val as string).trim(), maxChars);
  }

  private static clamp(text: string, maxChars: number): string {
    if (maxChars > 0 && text.length > maxChars) {
      return text.substring(0, maxChars);
    }
    return text;
  }

  private static isHttpUrl(url: string): boolean {
    const lower: string = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  /** 主机名提取（无 @ohos.url 依赖）：去协议、去 userinfo、去端口与路径。 */
  private static hostOf(url: string): string {
    let rest: string = url;
    const schemeAt: number = rest.indexOf('://');
    if (schemeAt >= 0) {
      rest = rest.substring(schemeAt + 3);
    }
    let end: number = rest.length;
    const slashAt: number = rest.indexOf('/');
    if (slashAt >= 0 && slashAt < end) {
      end = slashAt;
    }
    const qAt: number = rest.indexOf('?');
    if (qAt >= 0 && qAt < end) {
      end = qAt;
    }
    let host: string = rest.substring(0, end);
    const atAt: number = host.indexOf('@');
    if (atAt >= 0) {
      host = host.substring(atAt + 1);
    }
    const colonAt: number = host.indexOf(':');
    if (colonAt >= 0) {
      host = host.substring(0, colonAt);
    }
    if (host.startsWith('www.')) {
      host = host.substring(4);
    }
    return host;
  }
}
