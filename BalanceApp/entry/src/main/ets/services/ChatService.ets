/*
 * ChatService.ets
 *
 * 流式与非流式对话引擎 —— 采用系统 @kit.NetworkKit 实现 OpenAI 兼容格式通信。
 * 对齐 Kimi《流式输出》《多轮对话（messages 记忆）》两节规范，按本项目实际裁剪落地：
 * 1. 流式：requestInStream + SSE 逐块解析（content 追加、reasoning_content 追加折叠、
 *    [DONE] 为完成判据、不以 finish_reason 判完）；role 仅首块、usage 终块 choices 为空
 *    均已容错。客户端函数调用（tool_calls）仍未支持，有意忽略其增量（n 恒为 1，不下发 n）；
 *    DeepSeek 服务端联网工具另走 choice.server_tool_event 与 delta.annotations，见 WebSearchService。
 * 2. 记忆：/chat/completions 无状态，每轮回传 system + 历史 user/assistant（按时间序）；
 *    system 常驻、历史截断取新（条数+字符双预算，见 buildApiMessages）。
 * 3. 中断：返回取消函数 destroy 旧连接（用户点停止即丢弃后续块）。
 * 4. token 用量：ChatUsage 已下线，故不下发 stream_options.include_usage，
 *    终块 usage 到达即忽略，不做 UI 统计。
 *
 * 严格遵守 ArkTS 规范：无 any/unknown，无解构，捕获异常转为 Error 类型。
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, CitationRange, MessageAttachment, sanitizeLocation } from '../models/ChatModels';
import { findProvider, ProviderDefinition } from './ProviderRegistry';
import { SearchProgress, WebSearchService } from './WebSearchService';

const DOMAIN = 0x0000;
const TAG = 'ChatService';
const CONNECT_TIMEOUT = 15000;
const READ_TIMEOUT = 90000;
/**
 * 历史截断预算（对齐 Kimi make_messages 取新 20 条 + 本项目群聊设计 6000 字预算）。
 * Business Rule: system 常驻不计入预算；历史超限从旧到新丢弃，保证请求稳定。
 */
const MAX_HISTORY_MESSAGES = 20;
const MAX_HISTORY_CHARS = 12000;

/** Date.getDay() 是 0(周日)~6(周六)；weekday 随语言切换（官方《用户元信息标记》）。 */
const ZH_WEEKDAYS: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
const EN_WEEKDAYS: string[] = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/** 待发消息条目：items 通常 1 条，user 消息可能多带一条 latest_reminder。 */
interface ApiMessageEntry {
  items: Record<string, ESObject>[];
  chars: number;
}

/**
 * 用户元信息标记（latest_reminder）的取值来源。
 * Business Rule: 只有 DeepSeek 认这个 role，其他服务商会 400，调用方按服务商决定是否传。
 */
export interface ReminderOptions {
  /** 所在地，可留空（官方允许空字段，可含逗号）。 */
  location: string;
  /** 'zh-CN' | 'en-US'：决定星期写法与 language 字段。 */
  language: string;
}

/** 模型返回的一次函数调用（客户端工具：生图）。 */
export interface ToolCallRequest {
  id: string;
  name: string;
  /** JSON 字符串，调用方按工具自行解析。 */
  arguments: string;
}

export interface StreamCallbacks {  onToken: (token: string, reasoningChunk?: string) => void;
  onComplete: () => void;
  onError: (error: string) => void;
  /** 服务端联网工具过程事件（deepseek_web_search）；未声明工具的请求不会回调。 */
  onSearch?: (progress: SearchProgress) => void;
  /** 服务端下发的引用位标（末块 annotations）；按区间保留，展示层再按 url 归并来源。 */
  onCitations?: (citations: CitationRange[]) => void;
  /**
   * 会话标题（仅首轮请求声明 title 时下发，位于最后一个 chunk 的 delta.title）。
   * Business Rule: 服务端不保证给标题（拒答/出错时没有），调用方需保留本地兜底标题。
   */
  onTitle?: (title: string) => void;
  /**
   * 客户端工具调用（本轮声明 generate_image 时可能出现）。
   * Business Rule: 流结束后一次性回调（arguments 分片已合并），由调用方执行工具并展示结果。
   */
  onToolCalls?: (calls: ToolCallRequest[]) => void;
  /** 内容安全拒答：finish_reason=content_filter 或 delta.refusal 时回调。 */
  onRefusal?: (reason: string) => void;
  /**
   * 服务端工具调用原文（末块 delta.server_tool_calls）。
   * Business Rule: 阅读链接的网页正文加密在 signature 里，调用方必须原样留存并随历史回传，
   *   下一轮模型才能继续引用该网页。
   */
  onServerToolCalls?: (json: string) => void;
}

export interface ChatRequestOptions {
  providerId: string;
  apiKey: string;
  model: string;
  temperature?: number;
  messages: ChatMessage[];
  systemPrompt?: string;
  /** 深度思考开关；仅当供应商 supportsThinking 时生效。 */
  enableThinking?: boolean;
  /** 思考强度 low/high/max；缺省 high。 */
  reasoningEffort?: string;
  /**
   * 联网搜索开关：声明 DeepSeek 服务端工具 deepseek_web_search。
   * Business Rule: 仅 DeepSeek 支持，是否真的发起搜索由模型判断（客户端不跑工具循环）。
   */
  enableWebSearch?: boolean;
  /**
   * 会话标题开关：声明 DeepSeek 的 `title:{enabled:true}`，回答末尾顺带返回简短标题。
   * Business Rule: 只在会话首轮开启（服务端最多多等 5 秒）；标题不计费。
   */
  enableTitle?: boolean;
  /**
   * 生图工具开关：声明客户端函数 generate_image，与联网搜索同形——声明后由模型判断
   * 用户是否真的要图，客户端不再按关键词猜意图。
   * Business Rule: 声明只受「图片生成」开关与服务商能力约束；缺百智云生图 Key 不在这里
   *   静默摘工具，而是执行阶段给出明确提示，避免「点了没反应」。
   */
  enableImageTool?: boolean;
  /** 内容安全：声明 safety_check.level=high（官方基础风控，输入输出都审核）。 */
  enableSafety?: boolean;
  /** 文件/图片附件解析开关（关闭时历史里的附件不再以 content 块回传）。 */
  enableFiles?: boolean;
  /**
   * 阅读链接开关：声明 deepseek_read_url，模型自动读用户消息里的 URL。
   * Business Rule: 开思考且同时开了联网搜索时，服务端走深度思考搜索、本轮不单独读链接
   *   （官方语义），请求照常成功，只是不产生 read_link 调用。
   */
  enableReadUrl?: boolean;
  /** 用户元信息标记（日期/星期/所在地/语言）；仅 DeepSeek 生效。 */
  reminder?: ReminderOptions;
}

export class ChatService {
  /**
   * 流式对话调用，返回用于中断取消的控制器对象
   */
  public static streamChat(options: ChatRequestOptions, callbacks: StreamCallbacks): () => void {
    const def: ProviderDefinition | undefined = findProvider(options.providerId);
    if (def === undefined) {
      callbacks.onError(`未知的服务商: ${options.providerId}`);
      return () => {};
    }

    if (options.apiKey.trim().length === 0) {
      callbacks.onError('未配置 API Key，请先配置');
      return () => {};
    }

    const endpointUrl: string = `${def.baseUrl}/v1/chat/completions`;
    const req: http.HttpRequest = http.createHttp();
    let isAborted: boolean = false;
    let textBuffer: string = '';
    let sawDone: boolean = false;
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    // 客户端工具调用：arguments 分片到达，按 index 累加，流结束后统一回调。
    const toolAcc: Map<number, ToolCallRequest> = new Map<number, ToolCallRequest>();
    // 内容安全拒答：safety_check 开启后，输出可能以 content_filter/refusal 结束。
    let refusalReason: string = '';

    // 多轮拼接：/chat/completions 无状态，须每轮回传 system + 历史（见 buildApiMessages）。
    const formattedMessages: Record<string, ESObject>[] =
      ChatService.buildApiMessages(options.messages, options.systemPrompt,
        options.providerId === 'deepseek' && options.enableFiles !== false,
        options.providerId === 'kimi' || options.providerId === 'mimo',
        options.providerId === 'deepseek' ? options.reminder : undefined);

    const payloadObj: Record<string, ESObject> = ChatService.buildPayload(options, def, formattedMessages, true);
    const bodyStr: string = JSON.stringify(payloadObj);

    // 绑定流式数据接收
    req.on('dataReceive', (chunkBuffer: ArrayBuffer) => {
      if (isAborted) {
        return;
      }
      try {
        const u8: Uint8Array = new Uint8Array(chunkBuffer);
        const chunkText: string = decoder.decodeWithStream(u8, { stream: true });
        textBuffer += chunkText;

        const lines: string[] = textBuffer.split('\n');
        // 最后一个元素可能是未截断完整的，留在 buffer 里
        const lastLine: string | undefined = lines.pop();
        textBuffer = lastLine !== undefined ? lastLine : '';

        let lineIdx: number = 0;
        while (lineIdx < lines.length) {
          const rawLine: string = lines[lineIdx].trim();
          lineIdx += 1;
          if (!rawLine.startsWith('data:')) {
            continue;
          }
          const dataStr: string = rawLine.substring(5).trim();
          // 完成判据只认 data:[DONE]（不对 finish_reason 做完成判断；中断走 err 回调）。
          if (dataStr === '[DONE]') {
            sawDone = true;
            continue;
          }

          try {
            const parsedChunk: ESObject = JSON.parse(dataStr) as ESObject;
            if (parsedChunk !== null && typeof parsedChunk === 'object') {
              const rootRec: Record<string, ESObject> = parsedChunk as Record<string, ESObject>;

              // 终块 usage 形如 {choices:[], usage:{...}}：choices 为空即跳过，
              // 本项目 token 统计已下线，不读取 usage。
              // 解析 delta content / reasoning_content（均为追加式增量，不可覆盖）；
              // role 仅首块出现，此处忽略；delta.tool_calls 由下方 mergeToolCalls 合并。
              const choices: ESObject = rootRec['choices'];
              if (Array.isArray(choices) && choices.length > 0) {
                const choiceItem: ESObject = choices[0];
                if (choiceItem !== null && typeof choiceItem === 'object') {
                  const choiceRec: Record<string, ESObject> = choiceItem as Record<string, ESObject>;
                  // 服务端联网工具事件与 delta 并列下发（一次 chunk 最多一个），
                  // 与 content/reasoning 增量无关，故先于 delta 处理。
                  const toolEventVal: ESObject = choiceRec['server_tool_event'];
                  if (toolEventVal !== null && typeof toolEventVal === 'object' &&
                    callbacks.onSearch !== undefined) {
                    const progress: SearchProgress | undefined = WebSearchService.parseToolEvent(toolEventVal);
                    if (progress !== undefined) {
                      callbacks.onSearch(progress);
                    }
                  }
                  const finishVal: ESObject = choiceRec['finish_reason'];
                  if (finishVal === 'content_filter') {
                    refusalReason = '内容未通过安全审核';
                  }
                  const delta: ESObject = choiceRec['delta'];
                  if (delta !== null && typeof delta === 'object') {
                    const deltaRec: Record<string, ESObject> = delta as Record<string, ESObject>;
                    const contentStr: string = typeof deltaRec['content'] === 'string' ? deltaRec['content'] as string : '';
                    const reasoningStr: string = typeof deltaRec['reasoning_content'] === 'string' ? deltaRec['reasoning_content'] as string : '';

                    if (contentStr.length > 0 || reasoningStr.length > 0) {
                      callbacks.onToken(contentStr, reasoningStr.length > 0 ? reasoningStr : undefined);
                    }
                    const refusalVal: ESObject = deltaRec['refusal'];
                    if (typeof refusalVal === 'string' && (refusalVal as string).length > 0) {
                      refusalReason = refusalVal as string;
                    }
                    // 客户端工具调用（generate_image）：delta.tool_calls 分片到达，按 index 合并。
                    const toolCallsVal: ESObject = deltaRec['tool_calls'];
                    if (Array.isArray(toolCallsVal)) {
                      ChatService.mergeToolCalls(toolCallsVal as ESObject[], toolAcc);
                    }
                    // 引用位标只在带 finish_reason 的末块 delta 里一次性下发；
                    // 与正文增量无关，故不并入 onToken，单独回调避免污染流式文本。
                    if (callbacks.onCitations !== undefined) {
                      const cites: CitationRange[] = WebSearchService.parseCitations(delta);
                      if (cites.length > 0) {
                        callbacks.onCitations(cites);
                      }
                    }
                    // 会话标题同样只出现在最后一个 chunk 的 delta 里。
                    if (callbacks.onTitle !== undefined) {
                      const titleVal: ESObject = deltaRec['title'];
                      if (typeof titleVal === 'string' && (titleVal as string).trim().length > 0) {
                        callbacks.onTitle((titleVal as string).trim());
                      }
                    }
                    // 服务端工具调用（含阅读链接 signature）同样只在末块一次性下发，原样留存。
                    if (callbacks.onServerToolCalls !== undefined) {
                      const stcJson: string =
                        WebSearchService.serializeServerToolCalls(deltaRec['server_tool_calls']);
                      if (stcJson.length > 0) {
                        // 诊断用：只记体积，不记 signature 内容（含网页正文密文）。
                        hilog.info(DOMAIN, TAG, 'server_tool_calls: %{public}d chars', stcJson.length);
                        callbacks.onServerToolCalls(stcJson);
                      }
                    }
                  }
                }
              }
            }
          } catch (_parseErr) {
            // 忽略单行非合法 JSON 的心跳片段
          }
        }
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'SSE decode error: %{public}s', String(err));
      }
    });

    req.on('dataEnd', () => {
      if (!isAborted) {
        if (!sawDone) {
          // 未收到 [DONE] 即关流：按不完整对待，仅打日志，仍以已收 token 落库（调用方已做 keep-partial）。
          hilog.warn(DOMAIN, TAG, 'Stream ended without [DONE], keep partial content');
        }
        // 拒答先于 onComplete 回调：调用方清空已展示文本并给拒答提示。
        if (refusalReason.length > 0 && callbacks.onRefusal !== undefined) {
          callbacks.onRefusal(refusalReason);
        }
        // 工具调用先于 onComplete 回调：调用方可在收尾时统一处理（生图任务）。
        if (callbacks.onToolCalls !== undefined && toolAcc.size > 0) {
          const calls: ToolCallRequest[] = ChatService.collectToolCalls(toolAcc);
          if (calls.length > 0) {
            callbacks.onToolCalls(calls);
          }
        }
        callbacks.onComplete();
      }
      try {
        req.destroy();
      } catch (_e) {
      }
    });

    // 发起 requestInStream 请求
    req.requestInStream(endpointUrl, {
      method: http.RequestMethod.POST,
      header: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${options.apiKey.trim()}`,
        'api-key': options.apiKey.trim(),
        'Accept': 'text/event-stream'
      },
      extraData: bodyStr,
      connectTimeout: CONNECT_TIMEOUT,
      readTimeout: READ_TIMEOUT
    }, (err: BusinessErrorLike | null | undefined) => {
      if (err) {
        if (!isAborted) {
          hilog.error(DOMAIN, TAG, 'Stream request failed: %{public}s', String(err));
          callbacks.onError(`网络请求失败: ${String(err)}`);
        }
        try {
          req.destroy();
        } catch (_e) {
        }
      }
    });

    // 返回取消打断函数
    return () => {
      isAborted = true;
      try {
        req.destroy();
      } catch (_e) {
      }
    };
  }

  /**
   * 非流式对话调用
   */
  public static async nonStreamChat(options: ChatRequestOptions): Promise<string> {
    const def: ProviderDefinition | undefined = findProvider(options.providerId);
    if (def === undefined) {
      throw new Error(`未知的服务商: ${options.providerId}`);
    }

    const endpointUrl: string = `${def.baseUrl}/v1/chat/completions`;
    const req: http.HttpRequest = http.createHttp();

    try {
      const formattedMessages: Record<string, ESObject>[] =
        ChatService.buildApiMessages(options.messages, options.systemPrompt,
          options.providerId === 'deepseek',
          options.providerId === 'kimi' || options.providerId === 'mimo',
          options.providerId === 'deepseek' ? options.reminder : undefined);

      const payloadObj: Record<string, ESObject> = ChatService.buildPayload(options, def, formattedMessages, false);

      const resp: http.HttpResponse = await req.request(endpointUrl, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${options.apiKey.trim()}`,
          'api-key': options.apiKey.trim(),
          'Accept': 'application/json'
        },
        extraData: JSON.stringify(payloadObj),
        connectTimeout: CONNECT_TIMEOUT,
        readTimeout: READ_TIMEOUT
      });

      if (resp.responseCode !== 200) {
        throw new Error(`服务商返回状态码 ${resp.responseCode}: ${String(resp.result)}`);
      }

      let parsed: ESObject;
      if (typeof resp.result === 'string') {
        parsed = JSON.parse(resp.result as string) as ESObject;
      } else {
        parsed = resp.result as ESObject;
      }

      const rootRec: Record<string, ESObject> = parsed as Record<string, ESObject>;
      const choices: ESObject = rootRec['choices'];
      if (!Array.isArray(choices) || choices.length === 0) {
        throw new Error('返回结果未包含任何文本回复');
      }

      const choiceRec: Record<string, ESObject> = choices[0] as Record<string, ESObject>;
      const msg: ESObject = choiceRec['message'];
      if (msg === null || typeof msg !== 'object') {
        throw new Error('回复消息结构非法');
      }

      const msgRec: Record<string, ESObject> = msg as Record<string, ESObject>;
      return typeof msgRec['content'] === 'string' ? msgRec['content'] as string : '';
    } finally {
      req.destroy();
    }
  }

  /**
   * 组装 API 用 messages：system 常驻首位 + 历史按时间序取新截断。
   * Business Rule: 对齐 Kimi make_messages（system 必带、超 n 仅保留最新 n 条），
   *   再叠加字符预算从旧到新丢弃；调用方传分支路径即可，此处统一收口流式/非流式。
   * Reason: 长会话无截断会撑爆上下文窗口导致 400/变慢；多会话隔离与持久化由
   *   ChatStorageService 按 session 存全量承担，此处只裁剪本次请求。
   */
  private static buildApiMessages(messages: ChatMessage[], systemPrompt: string | undefined,
    enableFiles: boolean, preserveThinking: boolean,
    reminder?: ReminderOptions): Record<string, ESObject>[] {
    const out: Record<string, ESObject>[] = [];
    if (systemPrompt !== undefined && systemPrompt.trim().length > 0) {
      const sysMsg: Record<string, ESObject> = {
        'role': 'system',
        'content': systemPrompt.trim()
      };
      out.push(sysMsg);
    }
    // 先过滤 user/assistant 并拼出待选（含 Preserved Thinking 回传）。
    const candidates: ApiMessageEntry[] = [];
    let reminderCount: number = 0;
    let toolCallReplayCount: number = 0;
    let i: number = 0;
    while (i < messages.length) {
      const m: ChatMessage = messages[i];
      i += 1;
      if (m.role !== 'user' && m.role !== 'assistant') {
        continue;
      }
      let replayContent: string = m.content;
      // 纯附件消息（只发文件不打字）也必须保留，否则追问会丢文档。
      const hasAtts: boolean = m.role === 'user' && enableFiles &&
        m.attachments !== undefined && m.attachments.length > 0;
      // 阅读链接：末块留存的 server_tool_calls 必须原样回传（signature 在里面），
      //   校验不过就按没有处理，请求照发。
      const replayedToolCalls: ESObject[] | undefined =
        m.role === 'assistant' && m.serverToolCallsJson !== undefined &&
        m.serverToolCallsJson.length > 0
          ? WebSearchService.parseServerToolCalls(m.serverToolCallsJson) : undefined;
      // Business Rule: 助手「空回合」（模型只调了客户端工具、没吐正文）不能原样回传——
      //   一个 content 为空、只有 reasoning 的 assistant 回合会让模型以为上一问还没答完，
      //   于是每轮都重复执行上一条生图指令（2026-11-20 实测：「我手里这是什么」「搜日照景点」
      //   都被它当成还要再生一张头像）。带图的旧回合用一句占位结算，其它空回合直接丢弃。
      //   唯一例外是带阅读链接的回合：正文可能为空，但 signature 必须回传。
      if (m.role === 'assistant' && replayContent.length === 0) {
        const hasImages: boolean = m.imageUrls !== undefined && m.imageUrls.length > 0;
        if (replayedToolCalls === undefined) {
          if (!hasImages) {
            continue;
          }
          replayContent = '（已为你生成图片）';
        }
      }
      // Preserved Thinking 只对 Kimi / 小米 MiMo 回传。DeepSeek 各模型若回传 reasoning_content，
      //   上一轮的「计划」会被带进新一轮（实测导致答题串味），必须丢弃。
      const hasReasoning: boolean = preserveThinking && m.reasoningContent !== undefined &&
        m.reasoningContent.length > 0;
      if (replayContent.length === 0 && !hasReasoning && !hasAtts &&
        replayedToolCalls === undefined) {
        continue;
      }
      const item: Record<string, ESObject> = {
        'role': m.role
      };
      let chars: number = replayContent.length;
      // 文档附件：只有 DeepSeek 支持 file 块；其他服务商退回纯文本，避免 400。
      const atts: MessageAttachment[] | undefined =
        m.role === 'user' && enableFiles ? m.attachments : undefined;
      if (atts !== undefined && atts.length > 0) {
        const parts: ESObject[] = [];
        let ai: number = 0;
        // Business Rule: 文档块在前、用户文字在后（官方示例顺序），模型据此定位问题。
        while (ai < atts.length) {
          const a: MessageAttachment = atts[ai];
          ai += 1;
          const filePart: Record<string, string> = { 'type': 'file', 'file_id': a.fileId };
          parts.push(filePart as ESObject);
          chars += a.fileName.length;
        }
        if (replayContent.length > 0) {
          const textPart: Record<string, string> = { 'type': 'text', 'text': replayContent };
          parts.push(textPart as ESObject);
        }
        item['content'] = parts as ESObject;
      } else {
        item['content'] = replayContent;
      }
      // 保留式思考（Preserved Thinking）：只对 Kimi/小米 MiMo 回传 reasoning_content 保多轮思维连贯。
      if (hasReasoning && m.reasoningContent !== undefined && m.reasoningContent.length > 0) {
        item['reasoning_content'] = m.reasoningContent;
        chars += m.reasoningContent.length;
      }
      if (replayedToolCalls !== undefined) {
        item['server_tool_calls'] = replayedToolCalls as ESObject;
        toolCallReplayCount += 1;
      }
      // 用户元信息标记：紧挨在它所属的 user 消息之前（协议要求，中间不能插别的消息）。
      const items: Record<string, ESObject>[] = [];
      if (reminder !== undefined && m.role === 'user') {
        items.push(ChatService.buildReminderEntry(m, reminder));
        chars += ChatService.REMINDER_CHARS;
        reminderCount += 1;
      }
      items.push(item);
      const entry: ApiMessageEntry = { items: items, chars: chars };
      candidates.push(entry);
    }
    // 条数截断：仅保留最新 MAX_HISTORY_MESSAGES 条。
    let start: number = 0;
    if (candidates.length > MAX_HISTORY_MESSAGES) {
      start = candidates.length - MAX_HISTORY_MESSAGES;
    }
    // 字符截断：从新到旧累加，超预算即丢弃更旧的。
    const kept: ApiMessageEntry[] = [];
    let used: number = 0;
    let j: number = candidates.length - 1;
    while (j >= start) {
      const c: ApiMessageEntry = candidates[j];
      if (kept.length > 0 && used + c.chars > MAX_HISTORY_CHARS) {
        break;
      }
      kept.unshift(c);
      used += c.chars;
      j -= 1;
    }
    // 诊断用：latest_reminder 是否真的进了请求（不含所在地等隐私字段，只看条数）。
    hilog.info(DOMAIN, TAG, 'reminder: %{public}d user turns', reminderCount);
    // 诊断用：阅读链接 signature 是否随历史回传（只记条数，不记内容）。
    hilog.info(DOMAIN, TAG, 'server_tool_calls replay: %{public}d turns', toolCallReplayCount);
    let k: number = 0;
    while (k < kept.length) {
      const unit: ApiMessageEntry = kept[k];
      let ui: number = 0;
      while (ui < unit.items.length) {
        out.push(unit.items[ui]);
        ui += 1;
      }
      k += 1;
    }
    return out;
  }

  /**
   * latest_reminder 的固定字符开销（日期/星期/语言），只用于本地历史预算。
   * 该消息不产生 token 费用差异，这里只是保守估计。
   */
  private static readonly REMINDER_CHARS: number = 32;

  /**
   * `<date>,<weekday>,<location>,App,<language>`（官方《用户元信息标记》）。
   * Business Rule: 日期取该条消息自己的时间，回放历史时每轮仍是当天的日期；
   *   language 必须用该语言自身书写（中文 / English），weekday 随之切换。
   */
  private static buildReminderEntry(m: ChatMessage, reminder: ReminderOptions): Record<string, ESObject> {
    const date: Date = new Date(m.createdAt);
    const year: string = `${date.getFullYear()}`;
    const monthNum: number = date.getMonth() + 1;
    const dayNum: number = date.getDate();
    const month: string = monthNum < 10 ? `0${monthNum}` : `${monthNum}`;
    const day: string = dayNum < 10 ? `0${dayNum}` : `${dayNum}`;
    const isEnglish: boolean = reminder.language === 'en-US';
    const weekdays: string[] = isEnglish ? EN_WEEKDAYS : ZH_WEEKDAYS;
    const weekday: string = weekdays[date.getDay()];
    const language: string = isEnglish ? 'English' : '中文';
    const location: string = sanitizeLocation(reminder.location);
    const entry: Record<string, ESObject> = {
      'role': 'latest_reminder',
      'content': `${year}-${month}-${day},${weekday},${location},App,${language}`
    };
    return entry;
  }

  /**
   * 生图工具的 JSON Schema 声明（DeepSeek function calling）。
   * Business Rule: 工具始终声明（能力就绪时），何时调用完全交给模型；描述里写清触发场景与
   *   不触发场景，避免模型把普通问答误判为生图，也避免它因为多了这个工具而跳过联网搜索。
   */
  private static buildImageToolDeclaration(): Record<string, ESObject> {
    const properties: Record<string, ESObject> = {
      'prompt': {
        'type': 'string',
        'description': '详细的中文画面描述：主体、场景、风格、构图、光影；把用户简短要求扩写成可生成的提示词'
      },
      'ratio': {
        'type': 'string',
        'enum': ['auto', '1:1', '4:3', '3:4', '16:9', '9:16'],
        'description': '画面比例，用户未指定时用 auto'
      },
      'count': {
        'type': 'integer',
        'description': '生成张数，1~4，默认 1'
      }
    };
    const parameters: Record<string, ESObject> = {
      'type': 'object',
      'properties': properties,
      'required': ['prompt']
    };
    const fn: Record<string, ESObject> = {
      'name': 'generate_image',
      'description': '根据文字描述生成图片。仅当用户明确要一张图片产物（画画、生成图片、海报、插画、' +
        '头像、壁纸、配图等视觉内容）时调用；普通问答、解释、代码、文案改写不要调用。' +
        '本工具与联网搜索互不排斥：用户既要最新信息又要图时，照常使用联网搜索。',
      'parameters': parameters
    };
    const decl: Record<string, ESObject> = {
      'type': 'function',
      'function': fn
    };
    return decl;
  }

  /** 合并 delta.tool_calls 分片（id/name 只到一次，arguments 逐段拼接）。 */
  private static mergeToolCalls(items: ESObject[], acc: Map<number, ToolCallRequest>): void {
    let i: number = 0;
    while (i < items.length) {
      const item: ESObject = items[i];
      i += 1;
      if (item === null || typeof item !== 'object') {
        continue;
      }
      const rec: Record<string, ESObject> = item as Record<string, ESObject>;
      const idxVal: ESObject = rec['index'];
      const index: number = typeof idxVal === 'number' ? idxVal as number : 0;
      let entry: ToolCallRequest | undefined = acc.get(index);
      if (entry === undefined) {
        const created: ToolCallRequest = { id: '', name: '', arguments: '' };
        acc.set(index, created);
        entry = created;
      }
      const idVal: ESObject = rec['id'];
      if (typeof idVal === 'string' && (idVal as string).length > 0) {
        entry.id = idVal as string;
      }
      const fnVal: ESObject = rec['function'];
      if (fnVal !== null && typeof fnVal === 'object') {
        const fnRec: Record<string, ESObject> = fnVal as Record<string, ESObject>;
        const nameVal: ESObject = fnRec['name'];
        if (typeof nameVal === 'string' && (nameVal as string).length > 0) {
          entry.name = nameVal as string;
        }
        const argsVal: ESObject = fnRec['arguments'];
        if (typeof argsVal === 'string') {
          entry.arguments += argsVal as string;
        }
      }
    }
  }

  private static collectToolCalls(acc: Map<number, ToolCallRequest>): ToolCallRequest[] {
    const out: ToolCallRequest[] = [];
    acc.forEach((value: ToolCallRequest) => {
      if (value.name.length > 0) {
        out.push(value);
      }
    });
    return out;
  }

  /**
   * 针对不同供应商（DeepSeek / 小米 MiMo / Kimi）规范构建差异化请求体
   */
  private static buildPayload(
    options: ChatRequestOptions,
    def: ProviderDefinition,
    formattedMessages: Record<string, ESObject>[],
    isStream: boolean
  ): Record<string, ESObject> {
    const payloadObj: Record<string, ESObject> = {
      'model': options.model,
      'messages': formattedMessages as ESObject,
      'stream': isStream
      // 有意不下发：n（Kimi k3/k2.6/k2.7 固定为 1，传>1 直接 400）、
      // stream_options.include_usage（token 统计已下线）。
    };

    // 联网搜索：仅 DeepSeek 声明服务端工具，搜索/抓取由服务端完成。
    // Business Rule: 声明后 temperature/top_p 等由服务端忽略（官方《被忽略的参数》），
    //   故保留下面的温度配置不影响行为，也无需为开关另开分支。
    const tools: ESObject[] = [];
    if (options.enableWebSearch === true && WebSearchService.isSupported(options.providerId)) {
      const webTools: Record<string, string>[] = WebSearchService.buildToolDeclaration();
      let wi: number = 0;
      while (wi < webTools.length) {
        tools.push(webTools[wi] as ESObject);
        wi += 1;
      }
    }
    // 阅读链接：与联网搜索可同时声明；服务端按「开思考 + 声明搜索」走深度思考搜索，
    // 只有关思考或未声明搜索时才读用户消息里的 URL。
    if (options.enableReadUrl === true && WebSearchService.isSupported(options.providerId)) {
      const readTools: Record<string, string>[] = WebSearchService.buildReadUrlDeclaration();
      let ri: number = 0;
      while (ri < readTools.length) {
        tools.push(readTools[ri] as ESObject);
        ri += 1;
      }
    }
    // 生图：客户端函数工具，可与上面的服务端搜索/阅读工具同时声明；
    // 模型自己决定要不要画，客户端只在收到 tool_calls 后执行百智云任务。
    if (options.enableImageTool === true && options.providerId === 'deepseek') {
      tools.push(ChatService.buildImageToolDeclaration() as ESObject);
    }
    if (tools.length > 0) {
      payloadObj['tools'] = tools as ESObject;
    }
    // 诊断用：联网搜索「不生效」时先看这一行，确认 tools 是否真的进了请求体。
    hilog.info(DOMAIN, TAG, 'request tools=%{public}d webSearch=%{public}s readUrl=%{public}s safety=%{public}s imageTool=%{public}s model=%{public}s',
      tools.length, String(options.enableWebSearch === true),
      String(options.enableReadUrl === true),
      String(options.enableSafety === true),
      String(options.enableImageTool === true), options.model);
    // 内容安全：官方 safety_check（high=基础风控，low 与不传等价）。
    if (options.enableSafety === true && options.providerId === 'deepseek') {
      const safety: Record<string, string> = { 'level': 'high' };
      payloadObj['safety_check'] = safety as ESObject;
    }

    // 会话标题：DeepSeek 扩展字段，与 tools 并列放在顶层；其他服务商不认这个字段，不能透传。
    if (options.enableTitle === true && options.providerId === 'deepseek') {
      const titleCfg: Record<string, boolean> = { 'enabled': true };
      payloadObj['title'] = titleCfg as ESObject;
    }

    const thinkingOn: boolean = options.enableThinking === true && def.supportsThinking === true;
    const modelLower: string = options.model.toLowerCase();

    // 1. Kimi (Moonshot) 模型分支
    if (options.providerId === 'kimi') {
      if (modelLower.startsWith('kimi-k3')) {
        // K3 始终推理，不传 thinking 参数，支持顶层 reasoning_effort ("low" / "high" / "max"，默认 "max")
        payloadObj['reasoning_effort'] = options.reasoningEffort !== undefined ? options.reasoningEffort : 'max';
      } else if (modelLower.includes('kimi-k2.7')) {
        // k2.7-code 始终思考，不传 thinking 参数，不传 temperature
      } else if (modelLower.startsWith('kimi-k2.6')) {
        // k2.6 通过 thinking.type 控制开关，不传 temperature
        const thinkingCfg: Record<string, string> = {
          'type': thinkingOn ? 'enabled' : 'disabled'
        };
        payloadObj['thinking'] = thinkingCfg as ESObject;
      } else {
        // 普通 moonshot 模型
        payloadObj['temperature'] = options.temperature !== undefined ? options.temperature : 0.7;
      }
      return payloadObj;
    }

    // 2. 小米 MiMo 分支：支持 thinking.type "enabled"/"disabled"，思考模式下不传 temperature 与 reasoning_effort
    if (options.providerId === 'mimo') {
      const thinkingCfg: Record<string, string> = {
        'type': thinkingOn ? 'enabled' : 'disabled'
      };
      payloadObj['thinking'] = thinkingCfg as ESObject;
      if (!thinkingOn) {
        payloadObj['temperature'] = options.temperature !== undefined ? options.temperature : 0.7;
      }
      return payloadObj;
    }

    // 3. DeepSeek 及其他通用服务商分支
    if (thinkingOn) {
      const thinkingCfg: Record<string, string> = { 'type': 'enabled' };
      payloadObj['thinking'] = thinkingCfg as ESObject;
      payloadObj['reasoning_effort'] = options.reasoningEffort !== undefined ? options.reasoningEffort : 'high';
    } else {
      if (def.supportsThinking === true) {
        const thinkingOff: Record<string, string> = { 'type': 'disabled' };
        payloadObj['thinking'] = thinkingOff as ESObject;
      }
      payloadObj['temperature'] = options.temperature !== undefined ? options.temperature : 0.7;
    }

    return payloadObj;
  }
}

interface BusinessErrorLike {
  code?: number;
  message?: string;
}




