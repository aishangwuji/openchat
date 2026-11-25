/*
 * ChatModels.ets
 *
 * 对话核心数据结构定义 —— 包含消息、会话、角色卡等。
 * 遵守 ArkTS 严格模式规范：无 any/unknown，无解构，强类型定义。
 */

export type MessageRole = 'user' | 'assistant' | 'system';

/**
 * 联网搜索结构化来源（DeepSeek 服务端工具 web_search_tool_result / url_citation）。
 * Business Rule: url 是来源的唯一身份，合并去重一律按 url；其余字段只用于展示，
 *   缺失时由界面兜底（站点名回退到主机名、标题回退到 url）。
 */
export interface SearchSource {
  url: string;
  title: string;
  snippet?: string;
  siteName?: string;
  siteIcon?: string;
  publishedAt?: string;
}

/**
 * 正文引用位标：服务端 annotations 下发的 url_citation 位置。
 * Business Rule: start/end 是**Unicode 码点**下标（官方协议语义），
 *   渲染前必须换算成 UTF-16 下标再用（见 MarkdownService.injectCitations）。
 */
export interface CitationRange {
  url: string;
  title: string;
  /** 引用起点（含），码点下标。 */
  start: number;
  /** 引用终点（不含），码点下标。 */
  end: number;
}

/**
 * 用户消息上的文档附件（DeepSeek Files API 的 file_id）。
 * Business Rule: 文档由服务端解析后只保留 file_id；请求里以
 *   content:[{type:'file', file_id}, {type:'text', text}] 引用，不再上传原文。
 */
export interface MessageAttachment {
  fileId: string;
  fileName: string;
  /** 上传时的解析方式：text_recognition / rich_layout_recognition / user_data。 */
  purpose: string;
  bytes: number;
  /**
   * 本机预览副本路径（仅图片有）：picker 的 URI 是临时的，重启后失效，
   * 所以选图时复制到 filesDir，用于气泡里直接显示缩略图。
   */
  localUri?: string;
}

export interface ChatMessage {
  id: string;
  role: MessageRole;
  content: string;
  reasoningContent?: string;
  /** 深度思考用时（秒，整数，用于还原 DeepSeek 思考用时显示）。 */
  thinkingDuration?: number;
  createdAt: number;
  status: 'sending' | 'streaming' | 'success' | 'error';
  errorMessage?: string;
  /** 父节点 id；根节点为 ''。 */
  parentId: string;
  /** 有序子节点 id 列表（承载多个分支/编辑版本）。 */
  childIds: string[];
  /** 当前激活的子分支 id；无子节点为 ''。 */
  activeChildId: string;
  /** 发言角色卡 id；用户消息为 ''；单聊助手消息为会话绑定的角色卡 id。 */
  speakerId: string;
  /** 本条用户消息 @ 的角色卡 id（助手消息为空）。 */
  mentionedIds: string[];
  /**
   * 联网搜索来源（按 url 去重、按出现顺序排列）。持久化，历史会话可直接回看来源卡片。
   * Reason: 服务端工具只在本轮把来源下发给客户端，后续轮次不再重现，故必须本地留存。
   */
  sources?: SearchSource[];
  /** 联网搜索过程态：searching=本轮仍在检索。实时字段，不持久化。 */
  searchState?: 'searching' | 'done';
  /** 搜索过程提示文案（由 WebSearchService 生成）。实时字段，不持久化。 */
  searchHint?: string;
  /** 回答是否被长度上限截断（finish_reason=length）。实时字段，不持久化。 */
  incomplete?: boolean;
  /** 生图任务态：generating=生成中（实时字段）；done/failed 持久化。 */
  imageState?: 'generating' | 'done' | 'failed';
  /** 生成图片 URL（持久化；百智云结果地址有时效，过期后展示占位）。 */
  imageUrls?: string[];
  /** 生图元数据（模型 | 比例 | 画质 | 耗时），用于成图上方的信息条。 */
  imageMeta?: string;
  /** 生图宽高比（宽/高），用于锁定容器比例，避免加载时布局抖动。 */
  imageAspect?: number;
  /** 生图提示词（失败重试用）。 */
  imagePrompt?: string;
  /** 生图进度文案或失败原因（实时字段，不持久化）。 */
  imageHint?: string;
  /**
   * 引用位标（annotations）：用于在正文对应位置插入可点的 [N](#cite-N) 角标。
   * 持久化——历史会话重开时仍要能还原角标位置。
   */
  citations?: CitationRange[];
  /** 用户消息携带的文档（DeepSeek Files API）；持久化，历史轮次继续以 file_id 引用。 */
  attachments?: MessageAttachment[];
  /**
   * 服务端工具调用原文（Chat Completions 末块 delta.server_tool_calls 的 JSON）。
   * Business Rule: 阅读链接的网页正文加密在 signature 里，多轮必须原样回传整段；
   *   存原文而不是重拼结构，回传前由 WebSearchService.parseServerToolCalls 校验。
   */
  serverToolCallsJson?: string;
}

export interface CharacterCard {
  id: string;
  name: string;
  avatarIcon: string; // 标识内置图标或首字母
  description: string;
  systemPrompt: string;
  firstMessage: string;
  temperature: number; // 默认 0.7
  /** 私有知识（已下线，统一集成到系统设定中；保留可选以兼容历史数据）。 */
  knowledge?: string;
  createdAt: number;
}

/**
 * 用户身份卡已下线（2026-11-20）：会话不再绑定「我扮演谁」，历史数据里的 userIdentityId 字段被忽略。
 */

export interface ChatSession {
  id: string;
  title: string;
  characterId: string;
  providerId: string;
  modelId: string;
  updatedAt: number;
  /** 扁平节点池：所有分支的节点都保留在此，靠 parent/child 关系组织成树。 */
  messages: ChatMessage[];
  /** 根节点 id 列表（首条消息被编辑会产生多个根分支）。 */
  rootIds: string[];
  /** 当前激活的根分支 id。 */
  activeRootId: string;
  /** 本场景参与的角色卡 id（群聊成员）；单聊为空。 */
  participantIds: string[];
  /** 会话模式：单聊沿用单角色逻辑，群聊走多角色链式生成。 */
  sceneMode: 'single' | 'group';
  /** 角色可见水位：characterId -> 可见首条消息之前的 msgId（缺省全部可见；Phase1 全员可见）。 */
  joinMap: Record<string, string>;
  /** 保密会话：打开该会话记录前必须通过人脸/指纹认证。 */
  isPrivate: boolean;
  /**
   * 是否已尝试过自动生成会话标题（首轮回答完成即置 true，不再重复请求）。
   * Business Rule: 服务端标题最多多等 5 秒且只在首轮有价值；用该位保证每个会话只试一次。
   */
  autoTitled: boolean;
}

export interface ModelInfo {
  id: string;
  name: string;
  description?: string;
}

/**
 * 所在地清洗：换行压成空格、去首尾空白、封顶 40 字（可留空）。
 * Business Rule: 该值会拼进 latest_reminder 的逗号分隔字段，
 *   换行/超长必须在这里收口，否则请求体可能畸形（官方要求 400 校验）。
 */
export function sanitizeLocation(raw: string): string {
  let cleaned: string = raw.replace(/\r/g, ' ').replace(/\n/g, ' ').trim();
  if (cleaned.length > 40) {
    cleaned = cleaned.substring(0, 40);
  }
  return cleaned;
}
