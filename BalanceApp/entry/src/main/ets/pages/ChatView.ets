/*
 * ChatView.ets
 *
 * 智能对话主界面（温润静奢主题）
 * 1. 禁用所有 Emoji 表情符，采用纯文本及标准图形；
 * 2. 隐藏滚动条（.scrollBar(BarState.Off)），滑动干净无多余条框；
 * 3. 严格使用厂商官方实时接口拉取真实可用模型列表。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, common, PermissionRequestResult } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  ChatMessage, ChatSession, CharacterCard, CitationRange, MessageAttachment, ModelInfo, MessageRole, SearchSource
} from '../models/ChatModels';
import { ChatService, StreamCallbacks, ToolCallRequest } from '../services/ChatService';
import { ImageGenService, ImageTaskStatus, IMAGE_POLL_INTERVAL_MS, IMAGE_TASK_TIMEOUT_MS } from '../services/ImageGenService';
import { ModelService } from '../services/ModelService';
import { ChatStorageService } from '../services/ChatStorageService';
import { UpdateService, UpdateInfo } from '../services/UpdateService';
import { AuthService } from '../services/AuthService';
import { ChatMessageDataSource } from '../services/ChatMessageDataSource';
import { chatProviders, ProviderDefinition, findProvider, isThinkingSupported } from '../services/ProviderRegistry';
import { SearchProgress, WebSearchService } from '../services/WebSearchService';
import { BaizhiWebSearchService } from '../services/BaizhiWebSearchService';
import { TtsCallbacks, TtsService } from '../services/TtsService';
import {
  SettingsService, KEY_FEATURE_TITLE, KEY_FEATURE_FILES, KEY_FEATURE_ASR, KEY_FEATURE_TTS,
  KEY_FEATURE_IMAGE, KEY_FEATURE_SAFETY, KEY_FEATURE_READ_URL, KEY_WEB_SEARCH_PROVIDER, WEB_SEARCH_PROVIDER_BAIZHI,
  KEY_USER_LOCATION
} from '../services/SettingsService';
import { FileUploadService, UploadedFile } from '../services/FileUploadService';
import { VoiceRecorder } from '../services/VoiceRecorder';
import { AsrService } from '../services/AsrService';
import { I18nService } from '../services/I18nService';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { ThinkingButton } from '../components/ThinkingButton';
import { WebSearchButton } from '../components/WebSearchButton';
import { MarkdownBody } from '../components/MarkdownBody';
import { MarkdownService, MdClickAction } from '../services/MarkdownService';
import { MarkdownController, ETypingMode } from 'fluid-markdown';
import { skinColor } from '../services/SkinService';

const DOMAIN = 0x0000;
const TAG = 'ChatView';
const PREFS_NAME = 'balance_prefs';
// 输入框固定高度（折叠态默认两行内滚动）与展开态高度，超出部分由 TextArea 内部滚动查看。
const INPUT_BASE_HEIGHT = 40;
const INPUT_EXPANDED_HEIGHT = 160;

/** 无角色卡时的中性兜底：不附带任何系统设定与开场白。 */
const EMPTY_CHARACTER: CharacterCard = {
  id: '', name: '', avatarIcon: '', description: '',
  systemPrompt: '', firstMessage: '', temperature: 0.7, knowledge: '', createdAt: 0,
};

/** 输入框里待发送的文档（上传/解析完成后才有 fileId）。 */
interface PendingFile {
  fileName: string;
  purpose: string;
  status: 'uploading' | 'ready';
  fileId: string;
  bytes: number;
  /** 图片的沙箱预览副本（非图片为 ''）。 */
  localUri: string;
}

@Component
export struct ChatView {
  /** 皮肤版本号：皮肤或明暗切换时自增（SkinService），驱动本组件按新调色板重绘。 */
  @StorageProp('skin_version') skinVersion: number = 0;
  // ── 核心状态 ──
  @State sessions: ChatSession[] = [];
  @State currentSessionId: string = '';
  /**
   * 草稿会话：应用启动 / 点「+ 新会话」时使用，尚未写入历史。
   * Business Rule: 空会话不落盘、不进历史抽屉；一旦产生消息（attach）立即提升为正式会话并持久化，
   *   这样「每次启动默认新会话」不会在历史里堆一堆空「新对话」。
   */
  private draftSession: ChatSession | undefined = undefined;
  @State characters: CharacterCard[] = [];
  @State currentCharacterId: string = '';
  @State currentProviderId: string = 'deepseek';
  @State currentModelId: string = '';
  @State currentApiKey: string = '';

  // 消息流与输入
  @State inputText: string = '';
  // 输入框展开态：折叠时固定两行高度内滚动，展开后可查看更全面的输入内容。
  @State inputExpanded: boolean = false;
  @State isGenerating: boolean = false;
  @State showJumpBottom: boolean = false;
  @State noticeText: string = '';
  @StorageProp('auto_collapse_thinking') autoCollapseThinking: boolean = true;
  @StorageProp('app_font_scale') appFontScale: number = 1.0;
  @StorageProp('app_appearance') appearance: string = 'system';
  // 解析后的实际深色态（system 跟随系统，由 SettingsService/EntryAbility 落存）。
  @StorageProp('app_dark') appDark: boolean = false;
  // 语言：仅用于让空态问候语随「设置 > 语言」立即重绘。
  @StorageProp('app_language') currentLang: string = 'zh-CN';
  // Markdown 流式驱动：仅存活中的流式消息持有（生成开始建、结束/停止/删会话时删）。
  private mdControllers: Map<string, MarkdownController> = new Map();
  private mdTypingBegun: string[] = [];
  // Typing 就绪态：库 onMarkdownTypingReady 回调后才允许 update（Begin 不丢失）。
  private mdTypingReady: string[] = [];
  // 流式刷新节流：token 高频到达时全表重建压垮 UI 线程 → 视感"一次性"；按 tick 合并。
  private lastRefreshAt: number = 0;
  private refreshPending: boolean = false;
  @State previewImage: string = '';
  // 思考折叠列表不是 @State；切换时通过 ChatMessageDataSource 精准刷新对应消息项。
  private collapsedReasons: string[] = [];
  @State enableThinking: boolean = true;
  /**
   * 联网搜索开关：全局偏好（balance_prefs 的 web_search_enabled），跨会话/重启保留。
   * Business Rule: 只有 DeepSeek 服务商会把它写进请求（tools 声明），其余服务商界面不展示该开关。
   */
  @State enableWebSearch: boolean = false;
  /** 工具开关（设置 > 工具）：页面用 @StorageProp 跟随设置实时生效。 */
  @StorageProp(KEY_FEATURE_TITLE) featureTitle: boolean = true;
  @StorageProp(KEY_FEATURE_FILES) featureFiles: boolean = true;
  @StorageProp(KEY_FEATURE_ASR) featureAsr: boolean = true;
  @StorageProp(KEY_FEATURE_TTS) featureTts: boolean = true;
  @StorageProp(KEY_FEATURE_IMAGE) featureImage: boolean = true;
  @StorageProp(KEY_FEATURE_SAFETY) featureSafety: boolean = false;
  /** 阅读链接开关：声明 deepseek_read_url，让模型读用户消息里的 URL。 */
  @StorageProp(KEY_FEATURE_READ_URL) featureReadUrl: boolean = true;
  /** 用户所在地（设置里可留空）：随 latest_reminder 告诉模型。 */
  @StorageProp(KEY_USER_LOCATION) userLocation: string = '';
  @StorageProp(KEY_WEB_SEARCH_PROVIDER) webSearchProvider: string = 'deepseek';
  /** 展开来源明细的消息 id（'' = 全部收起）；点「N 个网页」胶囊切换。 */
  @State expandedSourceMsgId: string = '';
  /** 正在朗读的消息 id（'' = 未朗读）；用于菜单文案与图标状态。 */
  @State readingMsgId: string = '';
  /** 输入框里已选、正在解析或已就绪的文档（最多 3 个）。 */
  @State pendingFiles: PendingFile[] = [];
  /** 附件来源面板（拍照 / 相册 / 文件）。 */
  @State showAttachSheet: boolean = false;
  /** 语音输入：录音中 / 识别中 / 已录秒数（输入框无文字时右侧显示麦克风）。 */
  @State recording: boolean = false;
  @State transcribing: boolean = false;
  @State recordSeconds: number = 0;
  /** 语音模式：true 时输入区变成「按住说话」，右侧显示键盘切回文字输入。 */
  @State voiceMode: boolean = false;
  private recordTimer: number = -1;
  /** 手指是否仍按在「按住说话」上（松手早于录音启动时用来自动收尾）。 */
  private holdDown: boolean = false;
  @State availableModels: ModelInfo[] = [];
  @State fetchingModels: boolean = false;
  @State configuredProviders: ProviderDefinition[] = [];

  // 弹窗与抽屉控制
  @State showDrawer: boolean = false;
  /** 历史抽屉的会话搜索关键词（按标题过滤，抽屉每次打开时清空）。 */
  @State sessionQuery: string = '';
  @State showModelPicker: boolean = false;
  @State showCharacterSheet: boolean = false;
  @State showCharEditDialog: boolean = false;

  // 消息操作（长按菜单 + 编辑重发）
  @State actionMsgId: string = '';
  @State showEditDialog: boolean = false;
  @State editMsgId: string = '';
  @State editMsgText: string = '';
  // 角色卡长按操作
  @State charActionId: string = '';
  @State showCharDeleteConfirm: boolean = false;
  // 新会话角色选择（单选，一次只绑定一个角色）
  @State pendingParticipants: string[] = [];
  // 角色卡面板模式：select=新会话选择，manage=角色管理
  @State characterSheetMode: 'select' | 'manage' = 'select';
  // @ 指定发言人（群聊）
  @State pendingMentions: string[] = [];
  @State showMentionPicker: boolean = false;
  // 历史会话长按操作（重命名/删除）
  @State sessActionId: string = '';
  @State showRenameDialog: boolean = false;
  @State renameText: string = '';
  @State showDeleteConfirm: boolean = false;

  // 角色卡编辑临时状态
  @State editingCharId: string = '';
  @State editingCharName: string = '';
  @State editingCharPrompt: string = '';
  @State editingCharFirstMsg: string = '';
  @State editingCharTemp: number = 0.7;

  // 消息流数据源：LazyForEach 只为视口内消息创建 Markdown 实例（见 ChatMessageDataSource 注释）。
  private msgSource: ChatMessageDataSource = new ChatMessageDataSource();

  // 滚动控制器
  private scroller: Scroller = new Scroller();
  private abortStreaming: () => void = () => {};
  private balancePrefs: preferences.Preferences | undefined = undefined;
  private seq: number = 0;
  // 顶部锚定滚动状态
  private userTookOver: boolean = false;
  private lastAnchorOffset: number = -1;
  private anchorCaptured: boolean = false;
  // 单条回复只锚定一次：记下已锚定的消息 id，防每 token 重复 scrollToIndex 把用户拖动拽回。
  private anchoredForMsgId: string = '';
  // 思考区内嵌滚动跟随：定高 380 + Scroll，流式超出后新文本沉底不可见，需在底部时跟底。
  private thinkScrollers: Map<string, Scroller> = new Map();
  // 流式诊断计数（完成时打一行 hilog，区分"服务端一次性下发"与"UI 未刷新"）。
  private reasonChunkCount: number = 0;
  private contentChunkCount: number = 0;
  // 当前流式生成的完成回调（停止时唤醒等待链，避免挂起）
  private resolveCurrent: (() => void) | undefined = undefined;

  async aboutToAppear(): Promise<void> {
    try {
      const uiCtx = this.getUIContext();
      const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
      await ChatStorageService.init(hostCtx);
      this.balancePrefs = await preferences.getPreferences(hostCtx, { name: PREFS_NAME });
      // 联网搜索偏好随 balance_prefs 持久化（与 API Key 同库，不额外引入新 Preferences 存储）。
      const webSearchPref: preferences.ValueType = await this.balancePrefs.get('web_search_enabled', false);
      this.enableWebSearch = webSearchPref === true;
      // 生图工具不再看 Key：开关打开且服务商是 DeepSeek 就声明，缺 Key 由执行阶段报错。

      // 加载角色卡
      this.characters = await ChatStorageService.loadCharacters();
      if (this.characters.length > 0) {
        this.currentCharacterId = this.characters[0].id;
      }

      // 加载会话，并清理旧版本遗留的空会话（历史曾因「每次启动新建」堆入空「新对话」）。
      const loaded: ChatSession[] = await ChatStorageService.loadSessions();
      const kept: ChatSession[] = [];
      let repaired: boolean = false;
      let si: number = 0;
      while (si < loaded.length) {
        const s0: ChatSession = loaded[si];
        // Business Rule: 应用被杀/被覆盖安装时，正在生图的回合并未落盘为 done/failed，
        //   重启后恢复成「可重试的失败态」，避免留下一个永远转圈或全空的助手气泡。
        let mi: number = 0;
        while (mi < s0.messages.length) {
          const m0: ChatMessage = s0.messages[mi];
          if (m0.imageState === 'generating') {
            m0.imageState = 'failed';
            m0.imageHint = '生成被中断，可点重试';
            repaired = true;
          }
          mi += 1;
        }
        if (s0.messages.length > 0) {
          kept.push(s0);
        }
        si += 1;
      }
      this.sessions = kept;
      if (repaired || kept.length !== loaded.length) {
        await ChatStorageService.saveSessions(kept);
      }
      // Business Rule: 每次应用重启都进入一个全新的空白会话（草稿，不落盘），不再自动恢复上次会话；
      //   保密会话（isPrivate）也因此不会在启动时被直接展开。
      await this.createNewSession();

      // 历史会话思考过程初始化默认折叠
      this.initCollapsedReasons();

      // 加载当前 Provider Key、已配置服务商列表并拉取可用模型
      await this.reloadApiKey();
      await this.loadConfiguredProviders();
      await this.refreshModelList();

      // 静默检查更新：12 小时节流，发现新版本只提示一次，不打断对话。
      this.checkUpdateSilently();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'aboutToAppear error: %{public}s', String(err));
    }
  }

  private async checkUpdateSilently(): Promise<void> {
    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const info: UpdateInfo | null = await UpdateService.checkIfDue(hostCtx);
      if (info !== null) {
        this.toast(`发现新版本 v${info.version}，可在「设置 > 关于」查看`);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'silent update check failed: %{public}s', String(err));
    }
  }

  /**
   * 执行生图工具：建任务 → 轮询 → 图片 URL 追加到助手消息。
   * Business Rule: 失败不阻塞对话（消息保留文字与失败原因）；只有 completed 才展示图片。
   *   单次最长 6 分钟（官方通常 1~5 分钟），超时给出可重试提示。
   */
  private async runImageTool(msg: ChatMessage, call: ToolCallRequest): Promise<void> {
    msg.imageState = 'generating';
    msg.imageHint = '正在生成图片…';
    this.rebuildSessionReference();
    // 立刻落盘：任务要跑近一分钟，中途被杀也能在重启后看到「生成被中断」而不是空白气泡。
    this.saveState();
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const key: string = await SettingsService.getImageKey(hostCtx);
      if (key.trim().length === 0) {
        throw new Error('未配置百智云「生图」Key（设置 > 工具）');
      }
      let prompt: string = '';
      let ratio: string = 'auto';
      let count: number = 1;
      try {
        const parsed: ESObject = JSON.parse(call.arguments) as ESObject;
        if (parsed !== null && typeof parsed === 'object') {
          const rec: Record<string, ESObject> = parsed as Record<string, ESObject>;
          const pVal: ESObject = rec['prompt'];
          if (typeof pVal === 'string') {
            prompt = (pVal as string).trim();
          }
          const rVal: ESObject = rec['ratio'];
          if (typeof rVal === 'string' && (rVal as string).length > 0) {
            ratio = rVal as string;
          }
          const cVal: ESObject = rec['count'];
          if (typeof cVal === 'number') {
            count = Math.max(1, Math.min(4, Math.round(cVal as number)));
          }
        }
      } catch (_parseErr) {
      }
      if (prompt.length === 0) {
        throw new Error('模型未给出画面描述');
      }
      msg.imagePrompt = prompt;
      msg.imageAspect = this.aspectOfRatio(ratio);
      hilog.info(DOMAIN, TAG, 'image task start: ratio=%{public}s count=%{public}d', ratio, count);
      const taskId: string = await ImageGenService.createTask(prompt, ratio, '2K', count, key);
      const startedAt: number = Date.now();
      let urls: string[] = [];
      while (Date.now() - startedAt < IMAGE_TASK_TIMEOUT_MS) {
        await this.sleep(IMAGE_POLL_INTERVAL_MS);
        const status: ImageTaskStatus = await ImageGenService.queryTask(taskId, key);
        if (status.status === 'completed') {
          urls = status.imageUrls;
          break;
        }
        if (status.status === 'failed') {
          throw new Error(status.message.length > 0 ? status.message : '生成失败');
        }
        msg.imageHint = `正在生成图片… ${Math.round((Date.now() - startedAt) / 1000)}s`;
        this.rebuildSessionReference();
      }
      if (urls.length === 0) {
        throw new Error('生成超时，请稍后重试');
      }
      msg.imageUrls = urls;
      msg.imageState = 'done';
      msg.imageHint = undefined;
      // Business Rule: 模型只调工具、没吐正文时，这里补一句「已生成」，
      //   让这一回合在历史里算「已作答」，否则模型下一轮会以为生图请求还没处理而重复生图。
      if (msg.content.length === 0) {
        msg.content = urls.length > 1 ? `已为你生成 ${urls.length} 张图片。` : '已为你生成图片。';
      }
      const seconds: number = Math.max(1, Math.round((Date.now() - startedAt) / 1000));
      msg.imageMeta = '百智云 | ' + ratio + ' | 2K | ' + seconds + 's';
      hilog.info(DOMAIN, TAG, 'image task done: %{public}d images', urls.length);
    } catch (err) {
      msg.imageState = 'failed';
      msg.imageHint = err instanceof Error ? err.message : String(err);
      hilog.warn(DOMAIN, TAG, 'image task failed: %{public}s', msg.imageHint);
    }
    this.rebuildSessionReference();
    this.saveState();
  }

  /** 失败重试：用保存的提示词重新发起一次生图（比例回退 auto）。 */
  private async retryImage(msg: ChatMessage): Promise<void> {
    if (msg.imagePrompt === undefined || msg.imagePrompt.length === 0) {
      return;
    }
    const args: Record<string, ESObject> = {
      'prompt': msg.imagePrompt,
      'ratio': 'auto',
      'count': 1
    };
    const call: ToolCallRequest = { id: '', name: 'generate_image', arguments: JSON.stringify(args) };
    msg.imageUrls = undefined;
    msg.imageState = 'generating';
    msg.imageHint = '正在重新生成图片…';
    this.rebuildSessionReference();
    await this.runImageTool(msg, call);
  }

  /** 复制图片直链（文本剪贴板）。 */
  private async copyImageLink(msg: ChatMessage): Promise<void> {
    if (msg.imageUrls === undefined || msg.imageUrls.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, msg.imageUrls[0]);
      await pasteboard.getSystemPasteboard().setData(data);
      this.toast('图片链接已复制');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'copy image link failed: %{public}s', String(err));
      this.toast('复制失败，请改用浏览器打开');
    }
  }
  /** 比例字符串 -> 宽高比数值（宽/高），用于锁定图片容器，避免加载时布局抖动。 */
  private aspectOfRatio(ratio: string): number {
    if (ratio === '4:3') {
      return 4 / 3;
    }
    if (ratio === '3:4') {
      return 3 / 4;
    }
    if (ratio === '16:9') {
      return 16 / 9;
    }
    if (ratio === '9:16') {
      return 9 / 16;
    }
    return 1;
  }

  private sleep(ms: number): Promise<void> {
    const promise: Promise<void> = new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
    return promise;
  }

  // ── 数据辅助逻辑 ──

  aboutToDisappear(): void {
    // 离开对话页即停朗读：避免音频在后台继续播放，也顺手释放 AVPlayer 与缓存文件。
    this.stopReadAloud();
    // 录音同理：离开页面直接丢弃未完成的录音。
    this.abortRecording();
  }

  private getCurrentSession(): ChatSession | undefined {
    const draft: ChatSession | undefined = this.draftSession;
    if (draft !== undefined && draft.id === this.currentSessionId) {
      return draft;
    }
    let i: number = 0;
    while (i < this.sessions.length) {
      if (this.sessions[i].id === this.currentSessionId) {
        return this.sessions[i];
      }
      i += 1;
    }
    return undefined;
  }

  // ── 分支树辅助 ──

  private findMessage(sess: ChatSession, id: string): ChatMessage | undefined {
    let i: number = 0;
    while (i < sess.messages.length) {
      if (sess.messages[i].id === id) {
        return sess.messages[i];
      }
      i += 1;
    }
    return undefined;
  }

  /** 当前激活分支的完整路径（从根沿 activeChildId 走到叶）。 */
  private activePath(): ChatMessage[] {
    const sess: ChatSession | undefined = this.getCurrentSession();
    const path: ChatMessage[] = [];
    if (!sess) {
      return path;
    }
    let cur: string = sess.activeRootId;
    let guard: number = 0;
    while (cur.length > 0 && guard < 2000) {
      guard += 1;
      const node: ChatMessage | undefined = this.findMessage(sess, cur);
      if (node === undefined) {
        break;
      }
      path.push(node);
      cur = node.activeChildId;
    }
    return path;
  }

  /** 从根到指定节点的路径（沿 parent 链回溯，与激活分支无关）。 */
  private pathToNode(sess: ChatSession, targetId: string): ChatMessage[] {
    const rev: ChatMessage[] = [];
    let cur: string = targetId;
    let guard: number = 0;
    while (cur.length > 0 && guard < 2000) {
      guard += 1;
      const node: ChatMessage | undefined = this.findMessage(sess, cur);
      if (node === undefined) {
        break;
      }
      rev.push(node);
      cur = node.parentId;
    }
    const path: ChatMessage[] = [];
    let i: number = rev.length - 1;
    while (i >= 0) {
      path.push(rev[i]);
      i -= 1;
    }
    return path;
  }

  /** 请求用历史：根到 target 的路径，仅保留有内容的 user/assistant 节点。 */
  private historyTo(sess: ChatSession, targetId: string): ChatMessage[] {
    const full: ChatMessage[] = this.pathToNode(sess, targetId);
    const out: ChatMessage[] = [];
    let i: number = 0;
    while (i < full.length) {
      const m: ChatMessage = full[i];
      if ((m.role === 'user' || m.role === 'assistant') && m.content.length > 0) {
        out.push(m);
      }
      i += 1;
    }
    return out;
  }

  /** 同一父节点下的兄弟（编辑版本/重新生成版本）；根消息的兄弟即 rootIds。 */
  private siblingsOf(sess: ChatSession, msg: ChatMessage): string[] {
    if (msg.parentId.length === 0) {
      return sess.rootIds;
    }
    const p: ChatMessage | undefined = this.findMessage(sess, msg.parentId);
    if (p === undefined) {
      return [msg.id];
    }
    return p.childIds;
  }

  private siblingIndex(sess: ChatSession, msg: ChatMessage): number {
    const sibs: string[] = this.siblingsOf(sess, msg);
    let i: number = 0;
    while (i < sibs.length) {
      if (sibs[i] === msg.id) {
        return i;
      }
      i += 1;
    }
    return 0;
  }

  private nextId(role: string): string {
    this.seq += 1;
    return `msg_${role}_${Date.now()}_${this.seq}`;
  }

  private buildMessage(role: MessageRole, content: string, parentId: string): ChatMessage {
    return {
      id: this.nextId(role),
      role: role,
      content: content,
      reasoningContent: role === 'assistant' ? '' : undefined,
      createdAt: Date.now(),
      status: 'success',
      parentId: parentId,
      childIds: [],
      activeChildId: '',
      speakerId: '',
      mentionedIds: [],
    };
  }

  /**
   * 草稿转正：首次写入消息时把草稿会话加入历史并落盘。
   * Reason: 空会话不应进历史；只有真正产生内容的会话才值得持久化。
   */
  private promoteDraftIfNeeded(sess: ChatSession): void {
    const draft: ChatSession | undefined = this.draftSession;
    if (draft === undefined || draft.id !== sess.id) {
      return;
    }
    this.draftSession = undefined;
    const nextList: ChatSession[] = [sess];
    let i: number = 0;
    while (i < this.sessions.length) {
      nextList.push(this.sessions[i]);
      i += 1;
    }
    this.sessions = nextList;
    this.saveState();
  }

  /** 将 node 挂到 parent 之下并激活该分支（parent 为空则作为新根）。 */
  private attach(sess: ChatSession, node: ChatMessage): void {
    this.promoteDraftIfNeeded(sess);
    sess.messages.push(node);
    if (node.parentId.length === 0) {
      sess.rootIds.push(node.id);
      sess.activeRootId = node.id;
      return;
    }
    const parent: ChatMessage | undefined = this.findMessage(sess, node.parentId);
    if (parent === undefined) {
      // 父节点缺失（不应发生）：退化为根，保证数据自洽。
      node.parentId = '';
      sess.rootIds.push(node.id);
      sess.activeRootId = node.id;
      return;
    }
    parent.childIds.push(node.id);
    parent.activeChildId = node.id;
  }

  private getCurrentCharacter(): CharacterCard {
    // Reason: 默认会话不绑定角色（空白），未显式选择角色时不做兜底，避免自带系统设定。
    let i: number = 0;
    while (i < this.characters.length) {
      if (this.characters[i].id === this.currentCharacterId) {
        return this.characters[i];
      }
      i += 1;
    }
    return EMPTY_CHARACTER;
  }

  private characterById(id: string): CharacterCard | undefined {
    let i: number = 0;
    while (i < this.characters.length) {
      if (this.characters[i].id === id) {
        return this.characters[i];
      }
      i += 1;
    }
    return undefined;
  }

  private characterName(id: string): string {
    const c: CharacterCard | undefined = this.characterById(id);
    return c !== undefined ? c.name : '';
  }

  /** 当前会话的群聊成员（按 participantIds 顺序）。 */
  private participantCards(): CharacterCard[] {
    const sess: ChatSession | undefined = this.getCurrentSession();
    const out: CharacterCard[] = [];
    if (!sess) {
      return out;
    }
    let i: number = 0;
    while (i < sess.participantIds.length) {
      const c: CharacterCard | undefined = this.characterById(sess.participantIds[i]);
      if (c !== undefined) {
        out.push(c);
      }
      i += 1;
    }
    return out;
  }

  private isGroupChat(): boolean {
    // [群聊下线已注释]
    /*
    const sess: ChatSession | undefined = this.getCurrentSession();
    return sess !== undefined && sess.sceneMode === 'group' && sess.participantIds.length > 0;
    */
    return false;
  }

  private toggleMention(id: string): void {
    const c: CharacterCard | undefined = this.characterById(id);
    if (c === undefined) {
      return;
    }
    const marker: string = `@${c.name}`;
    const next: string[] = [];
    let found: boolean = false;
    let i: number = 0;
    while (i < this.pendingMentions.length) {
      if (this.pendingMentions[i] === id) {
        found = true;
      } else {
        next.push(this.pendingMentions[i]);
      }
      i += 1;
    }
    if (found) {
      // 取消 @：同步去掉输入框中的标记。
      this.inputText = this.inputText.split(marker).join('').trim();
      this.pendingMentions = next;
      return;
    }
    next.push(id);
    this.pendingMentions = next;
    if (!this.inputText.includes(marker)) {
      this.inputText = this.inputText.length > 0 ? `${this.inputText} ${marker} ` : `${marker} `;
    }
  }

  private removeMention(id: string): void {
    const c: CharacterCard | undefined = this.characterById(id);
    const next: string[] = [];
    let i: number = 0;
    while (i < this.pendingMentions.length) {
      if (this.pendingMentions[i] !== id) {
        next.push(this.pendingMentions[i]);
      }
      i += 1;
    }
    this.pendingMentions = next;
    if (c !== undefined) {
      this.inputText = this.inputText.split(`@${c.name}`).join('').trim();
    }
  }

  private isCjkChar(ch: string): boolean {
    if (ch.length === 0) {
      return false;
    }
    const code: number = ch.charCodeAt(0);
    return code >= 0x4e00 && code <= 0x9fff;
  }

  /**
   * 从文本中扫描 `@名字` 补齐 @（兼容手输，不依赖选择器）。
   * Reason: 手输 @ 若不识别会落到默认发言人，内容虽合理但名字对不上造成混淆；
   *   要求名字后紧跟非中文或结尾，避免短名误吞长名（如“姚”吞“姚瑶”）。
   */
  private extractMentions(sess: ChatSession, text: string): string[] {
    const out: string[] = [];
    let i: number = 0;
    while (i < sess.participantIds.length) {
      const pid: string = sess.participantIds[i];
      const pname: string = this.characterName(pid);
      if (pname.length > 0) {
        const marker: string = `@${pname}`;
        let from: number = 0;
        let hit: boolean = false;
        while (from <= text.length - marker.length) {
          const idx: number = text.indexOf(marker, from);
          if (idx < 0) {
            break;
          }
          const after: number = idx + marker.length;
          if (after >= text.length || !this.isCjkChar(text.charAt(after))) {
            hit = true;
            break;
          }
          from = idx + 1;
        }
        if (hit && !out.includes(pid)) {
          out.push(pid);
        }
      }
      i += 1;
    }
    return out;
  }

  private mentionText(msg: ChatMessage): string {
    let out: string = '';
    let i: number = 0;
    while (i < msg.mentionedIds.length) {
      const n: string = this.characterName(msg.mentionedIds[i]);
      if (n.length > 0) {
        if (out.length > 0) {
          out += ' ';
        }
        out += `@${n}`;
      }
      i += 1;
    }
    return out;
  }

  /** 群聊默认发言人：激活分支最后一位参与者，否则首位参与者，否则 ''。 */
  private defaultSpeaker(sess: ChatSession): string {
    const path: ChatMessage[] = this.activePath();
    let i: number = path.length - 1;
    while (i >= 0) {
      const m: ChatMessage = path[i];
      if (m.role === 'assistant' && m.speakerId.length > 0 && sess.participantIds.includes(m.speakerId)) {
        return m.speakerId;
      }
      i -= 1;
    }
    if (sess.participantIds.length > 0 && this.characterById(sess.participantIds[0]) !== undefined) {
      return sess.participantIds[0];
    }
    return '';
  }

  private currentProviderSupportsThinking(): boolean {
    return isThinkingSupported(this.currentProviderId, this.currentModelId);
  }

  /**
   * 联网搜索开关：先就地生效，再落 Preferences（失败只记日志，不影响本轮可用性）。
   * Business Rule: 只影响后续请求，已生成的历史消息不回写；切换服务商不重置该偏好。
   */
  private async setWebSearch(enabled: boolean): Promise<void> {
    this.enableWebSearch = enabled;
    if (this.balancePrefs === undefined) {
      return;
    }
    try {
      await this.balancePrefs.put('web_search_enabled', enabled);
      await this.balancePrefs.flush();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'persist web_search_enabled failed: %{public}s', String(err));
    }
  }

  private openSettings(): void {
    try {
      const ctx = this.getUIContext();
      ctx.getRouter().pushUrl({ url: 'pages/Settings' }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'push Settings failed: %{public}s', String(e));
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'push Settings error: %{public}s', String(err));
    }
  }

  private async reloadApiKey(): Promise<void> {
    if (!this.balancePrefs) {
      return;
    }
    try {
      const keyVal: preferences.ValueType = await this.balancePrefs.get(`key_${this.currentProviderId}`, '');
      if (typeof keyVal === 'string') {
        this.currentApiKey = keyVal as string;
      } else {
        this.currentApiKey = '';
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to reload API key: %{public}s', String(err));
    }
  }

  private async refreshModelList(): Promise<void> {
    this.fetchingModels = true;
    try {
      this.availableModels = await ModelService.fetchModels(this.currentProviderId, this.currentApiKey);
      if (this.availableModels.length > 0) {
        // 校验当前选中的 model 是否在拉取列表中，不在则默认第一个
        let found: boolean = false;
        let i: number = 0;
        while (i < this.availableModels.length) {
          if (this.availableModels[i].id === this.currentModelId) {
            found = true;
            break;
          }
          i += 1;
        }
        if (!found) {
          this.currentModelId = this.availableModels[0].id;
          const cur: ChatSession | undefined = this.getCurrentSession();
          if (cur) {
            cur.modelId = this.currentModelId;
          }
          this.saveState();
        }
      } else {
        this.currentModelId = '选择模型';
      }
    } finally {
      this.fetchingModels = false;
    }
  }

  /** 仅列出本地已配置 API Key 的服务商（未填 Key 的不展示；余额专用供应商不在列）。 */
  private async loadConfiguredProviders(): Promise<void> {
    const out: ProviderDefinition[] = [];
    const candidates: ProviderDefinition[] = chatProviders();
    if (this.balancePrefs) {
      let i: number = 0;
      while (i < candidates.length) {
        const p: ProviderDefinition = candidates[i];
        i += 1;
        try {
          const kv: preferences.ValueType = await this.balancePrefs.get(`key_${p.id}`, '');
          if (typeof kv === 'string' && (kv as string).trim().length > 0) {
            out.push(p);
          }
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'read key failed for %{public}s', p.id);
        }
      }
    }
    this.configuredProviders = out;
  }

  private async saveState(): Promise<void> {
    await ChatStorageService.saveSessions(this.sessions);
    await ChatStorageService.saveActiveSessionId(this.currentSessionId);
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 80);
  }

  // ── 流式顶部锚定滚动（Auto Scroll Top Anchor） ──
  // Business Rule: 流式生成时不跟随底部，而是把当前回答首行推到容器顶部后停住；
  //   后续 token 只增加内容高度，视口不动。用户手动滚动则暂停锚定。

  private scheduleAnchor(msgId: string): void {
    // Business Rule: 非生成态（历史浏览/图片后加载）一律不锚定；用户接管后不锚定；
    //   同一条回复只锚定一次 —— 顶部固定后内容向下生长视口自然不动，无需每 token 重推。
    //   异步时序推演：若顺序颠倒（用户先拖动、首 token 后到），userTookOver 已置 true，
    //   本次锚定跳过，用户停留在自己的位置，不会被拽回。
    if (!this.isGenerating || this.userTookOver || msgId.length === 0 || this.anchoredForMsgId === msgId) {
      return;
    }
    const targetId: string = msgId;
    setTimeout(() => {
      this.anchorStreamingReply(targetId);
    }, 0);
  }

  private anchorStreamingReply(msgId: string): void {
    if (!this.isGenerating || this.userTookOver || this.anchoredForMsgId === msgId) {
      return;
    }
    const path: ChatMessage[] = this.activePath();
    if (path.length === 0) {
      return;
    }
    const idx: number = path.length - 1;
    try {
      // ScrollAlign.START：把末条（当前回答）首行对齐容器顶部；内容不足时自动收敛为跟底。
      this.scroller.scrollToIndex(idx, false, ScrollAlign.START);
      // 锚定成功才落标记：抛异常则不记，下个 token 可重试。
      this.anchoredForMsgId = msgId;
      hilog.info(DOMAIN, TAG, 'anchored reply to index %{public}d', idx);
      this.anchorCaptured = false;
      setTimeout(() => {
        try {
          this.lastAnchorOffset = this.scroller.currentOffset().yOffset;
          this.anchorCaptured = true;
        } catch (_e) {
        }
      }, 24);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'anchor failed: %{public}s', String(err));
    }
  }

  private handleScrollIndex(start: number, end: number): void {
    const totalCount: number = this.activePath().length;
    if (totalCount <= 1) {
      if (this.showJumpBottom) {
        this.showJumpBottom = false;
      }
      return;
    }

    // end 是当前屏幕中可见的最末一条消息的索引
    const isAtBottom: boolean = end >= totalCount - 1;

    if (isAtBottom) {
      // 当前视口已显示最后一条消息（处于最底部）：立即隐藏按钮
      if (this.showJumpBottom) {
        this.showJumpBottom = false;
      }
      if (this.userTookOver) {
        this.userTookOver = false;
      }
    } else {
      // 最后一条消息已被滚出视口下方（用户往上翻阅历史）：显示“回到底部”
      if (!this.showJumpBottom) {
        this.showJumpBottom = true;
      }
      this.userTookOver = true;
    }
  }

  private onChatScrollStop(): void {
    try {
      if (this.scroller.isAtEnd()) {
        this.showJumpBottom = false;
        this.userTookOver = false;
        return;
      }
      // 条目内接管检测：onScrollIndex 只能感知条目间滚动（end < total-1），
      //   在超长单条气泡内部拖动时 end 恒为末条，必须用 offset 差值判定，
      //   否则流式中用户在回答内部的任何拖动都会被下一次锚定拽回（体感"拉不动"）。
      if (this.anchorCaptured && this.anchoredForMsgId.length > 0) {
        const cur: number = this.scroller.currentOffset().yOffset;
        const drift: number = Math.abs(cur - this.lastAnchorOffset);
        if (drift > 30) {
          this.userTookOver = true;
          this.showJumpBottom = true;
        }
      }
    } catch (_e) {
    }
  }

  private jumpToBottom(): void {
    this.userTookOver = false;
    this.showJumpBottom = false;
    this.scroller.scrollEdge(Edge.Bottom);
  }

  /** 输入框获焦：键盘弹起后最新内容可能被遮挡，把列表底到底（生成中保持锚定不动）。 */
  private onInputFocus(): void {
    if (this.isGenerating) {
      return;
    }
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 120);
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 380);
  }

  // ── 会话管理 ──

  /**
   * 对话区右滑打开历史抽屉。
   * 阈值取 60vp：略大于横向滑动的起手抖动，又明显小于半屏宽度，轻扫即开、不会误触。
   */
  private drawerSwipeThreshold: number = 60;
  // 一次右滑过程中累计的横向位移（vp），松手时据此判定是否达到阈值。
  private drawerSwipeOffset: number = 0;

  /** 是否有全屏弹层遮挡：此时右滑不应把抽屉推到弹层背后。 */
  private hasOverlayOnTop(): boolean {
    return this.showDrawer || this.showModelPicker || this.showCharacterSheet
      || this.showCharEditDialog || this.showEditDialog || this.showCharDeleteConfirm
      || this.showMentionPicker
      || this.showRenameDialog || this.showDeleteConfirm || this.previewImage.length > 0;
  }

  /** 右滑手势结算：达阈值且无弹层遮挡时拉开历史抽屉。 */
  private settleDrawerSwipe(): void {
    const offset: number = this.drawerSwipeOffset;
    this.drawerSwipeOffset = 0;
    if (offset < this.drawerSwipeThreshold || this.hasOverlayOnTop()) {
      return;
    }
    this.openDrawer();
  }

  /**
   * 打开历史抽屉。
   * Reason: 抽屉是整屏浮层，输入法键盘留在屏幕上会把窗口压缩成半屏，抽屉跟着变形；
   *   打开前先收焦点让键盘落下（无输入框聚焦时调用无副作用）。
   */
  private openDrawer(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'clearFocus before drawer failed: %{public}s', String(err));
    }
    this.sessionQuery = '';
    this.showDrawer = true;
  }

  /**
   * 历史抽屉的关键词过滤：只按会话标题匹配（大小写不敏感）。
   * 关键词为空时直接返回全量引用，避免每次输入都复制一遍会话数组。
   */
  private filteredSessions(): ChatSession[] {
    const keyword: string = this.sessionQuery.trim().toLowerCase();
    if (keyword.length === 0) {
      return this.sessions;
    }
    const matched: ChatSession[] = [];
    for (let i = 0; i < this.sessions.length; i++) {
      const sess: ChatSession = this.sessions[i];
      if (sess.title.toLowerCase().includes(keyword)) {
        matched.push(sess);
      }
    }
    return matched;
  }

  private toast(text: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: text });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'showToast failed: %{public}s', String(err));
    }
  }

  private async createNewSession(): Promise<void> {
    // 朗读属于某条回复：换会话先停，避免旧会话的音频继续播。
    this.stopReadAloud();
    // Business Rule: 新会话默认空白、不绑定角色；角色只能在“新会话”时选择，选中后锁定。
    const newId: string = `session_${Date.now()}`;
    const newSession: ChatSession = {
      id: newId,
      title: '新对话',
      characterId: '',
      providerId: this.currentProviderId,
      modelId: this.currentModelId,
      updatedAt: Date.now(),
      messages: [],
      rootIds: [],
      activeRootId: '',
      participantIds: [],
      sceneMode: 'single',
      joinMap: {},
      isPrivate: false,
      autoTitled: false,
    };
    this.currentCharacterId = '';

    // Business Rule: 空会话作为草稿存在，不进历史、不落盘；产生首条消息时才转正（见 promoteDraftIfNeeded）。
    this.draftSession = newSession;
    this.currentSessionId = newId;
    this.pendingMentions = [];
    this.showMentionPicker = false;
    this.anchoredForMsgId = '';
    this.anchorCaptured = false;
    this.syncMessageSource();
    this.scrollToBottom();
  }

  /**
   * 切换当前会话。
   * @param sessionId 目标任务会话 id。
   * @param closeDrawer 是否收起历史抽屉（删除会话时为 false，便于连续删除）。
   */
  private async switchSession(sessionId: string, closeDrawer: boolean = true): Promise<void> {
    this.stopReadAloud();
    // 切到正式会话时丢弃未使用的空草稿（有内容的草稿已在 attach 时转正）。
    if (this.draftSession !== undefined && this.draftSession.id !== sessionId) {
      this.draftSession = undefined;
    }
    this.currentSessionId = sessionId;
    this.pendingMentions = [];
    this.showMentionPicker = false;
    const cur: ChatSession | undefined = this.getCurrentSession();
    if (cur) {
      this.currentProviderId = cur.providerId;
      this.currentModelId = cur.modelId;
      this.currentCharacterId = cur.characterId;
      await this.reloadApiKey();
      await this.refreshModelList();
    }
    if (closeDrawer) {
      this.showDrawer = false;
    }
    this.initCollapsedReasons();
    this.anchoredForMsgId = '';
    this.anchorCaptured = false;
    this.syncMessageSource();
    await ChatStorageService.saveActiveSessionId(sessionId);
    this.scrollToBottom();
  }

  private async deleteSession(sessionId: string): Promise<void> {
    let victim: ChatSession | undefined = undefined;
    let vi: number = 0;
    while (vi < this.sessions.length) {
      if (this.sessions[vi].id === sessionId) {
        victim = this.sessions[vi];
        break;
      }
      vi += 1;
    }
    if (victim !== undefined) {
      this.dropSessionControllers(victim);
    }
    const nextList: ChatSession[] = [];
    let i: number = 0;
    while (i < this.sessions.length) {
      if (this.sessions[i].id !== sessionId) {
        nextList.push(this.sessions[i]);
      }
      i += 1;
    }
    this.sessions = nextList;

    if (this.currentSessionId === sessionId) {
      // Business Rule: 保密会话不能在删除当前会话后被自动展开（绕过认证）；
      //   优先切到最近的非保密会话，若全部为保密则新建空白会话。
      const nextId: string = this.firstNonPrivateSessionId();
      if (nextId.length > 0) {
        // Reason: 删除当前会话后必须像 switchSession 一样重同步 provider/model/key，
        //   否则头部仍显示被删会话的模型、发送会用错厂商（见 switchSession 同构逻辑）。
        //   传入 closeDrawer=false：删除后保留历史抽屉，便于用户连续删除其他会话。
        await this.switchSession(nextId, false);
      } else {
        await this.createNewSession();
      }
    }
    await this.saveState();
  }

  private firstNonPrivateSessionId(): string {
    let i: number = 0;
    while (i < this.sessions.length) {
      if (!this.sessions[i].isPrivate) {
        return this.sessions[i].id;
      }
      i += 1;
    }
    return '';
  }

  // ── 角色卡选择与编辑 ──

  private togglePendingParticipant(id: string): void {
    // Business Rule: 群聊已下线，新会话只绑定单个角色（单选）；再次点已选中的角色即取消。
    if (this.pendingParticipants.length === 1 && this.pendingParticipants[0] === id) {
      this.pendingParticipants = [];
    } else {
      this.pendingParticipants = [id];
    }
  }

  private isPendingParticipant(id: string): boolean {
    return this.pendingParticipants.includes(id);
  }

  /** 确认建联：绑定单个角色（含开场白）；群聊已下线，只支持单聊。 */
  private async confirmParticipants(): Promise<void> {
    if (this.pendingParticipants.length === 0) {
      return;
    }
    const cur: ChatSession | undefined = this.getCurrentSession();
    if (!cur) {
      this.showCharacterSheet = false;
      return;
    }
    // Business Rule: 角色只能绑定一次；会话已有绑定则锁定，不可更改。
    if (cur.characterId.length > 0 || cur.participantIds.length > 0) {
      this.showCharacterSheet = false;
      this.pendingParticipants = [];
      this.toast('该会话已绑定角色，无法更改');
      return;
    }
    const ids: string[] = [];
    let i: number = 0;
    while (i < this.pendingParticipants.length) {
      if (this.characterById(this.pendingParticipants[i]) !== undefined) {
        ids.push(this.pendingParticipants[i]);
      }
      i += 1;
    }
    if (ids.length === 0) {
      return;
    }
    cur.participantIds = ids;
    // [群聊下线已注释] 始终进入单聊模式
    /*
    if (ids.length >= 2) {
      cur.sceneMode = 'group';
      cur.characterId = '';
      this.currentCharacterId = '';
    } else {
    */
    cur.sceneMode = 'single';
    cur.characterId = ids[0];
    this.currentCharacterId = ids[0];
    const c: CharacterCard | undefined = this.characterById(ids[0]);
    if (c !== undefined && cur.messages.length === 0 && c.firstMessage.trim().length > 0) {
      const welcomeMsg: ChatMessage = this.buildMessage('assistant', c.firstMessage, '');
      this.attach(cur, welcomeMsg);
    }
    // }
    this.pendingParticipants = [];
    this.showCharacterSheet = false;
    this.rebuildSessionReference();
    await this.saveState();
    this.scrollToBottom();
  }

  private openCharEdit(char?: CharacterCard): void {
    if (char) {
      this.editingCharId = char.id;
      this.editingCharName = char.name;
      this.editingCharPrompt = char.systemPrompt;
      this.editingCharFirstMsg = char.firstMessage;
      this.editingCharTemp = char.temperature;
    } else {
      this.editingCharId = '';
      this.editingCharName = '';
      // Business Rule: 不预填任何「你是一个人工智能助手」式套话，角色设定与开场白由用户自己写。
      this.editingCharPrompt = '';
      this.editingCharFirstMsg = '';
      this.editingCharTemp = 0.7;
    }
    this.showCharEditDialog = true;
  }

  private async saveCharacterEdit(): Promise<void> {
    if (this.editingCharName.trim().length === 0) {
      return;
    }
    const nextChars: CharacterCard[] = [];
    const isNew: boolean = this.editingCharId.length === 0;

    let i: number = 0;
    while (i < this.characters.length) {
      const c: CharacterCard = this.characters[i];
      if (c.id === this.editingCharId) {
        const updated: CharacterCard = {
          id: c.id,
          name: this.editingCharName.trim(),
          avatarIcon: c.avatarIcon,
          description: c.description,
          systemPrompt: this.editingCharPrompt.trim(),
          firstMessage: this.editingCharFirstMsg.trim(),
          temperature: this.editingCharTemp,
          createdAt: c.createdAt
        };
        nextChars.push(updated);
      } else {
        nextChars.push(c);
      }
      i += 1;
    }

    if (isNew) {
      const created: CharacterCard = {
        id: `char_${Date.now()}`,
        name: this.editingCharName.trim(),
        avatarIcon: 'custom',
        description: '',
        systemPrompt: this.editingCharPrompt.trim(),
        firstMessage: this.editingCharFirstMsg.trim(),
        temperature: this.editingCharTemp,
        createdAt: Date.now()
      };
      nextChars.unshift(created);
      this.currentCharacterId = created.id;
      // 选择模式下，新建角色直接作为本次建联选择（单选）。
      if (this.characterSheetMode === 'select') {
        this.pendingParticipants = [created.id];
      }
    }

    this.characters = nextChars;
    this.showCharEditDialog = false;
    await ChatStorageService.saveCharacters(this.characters);
  }

  // ── 历史会话长按操作 ──

  private openSessActions(id: string): void {
    if (this.isGenerating) {
      return;
    }
    this.sessActionId = id;
  }

  private closeSessActions(): void {
    this.sessActionId = '';
  }

  private sessActionTitle(): string {
    const target: ChatSession | undefined = this.sessionById(this.sessActionId);
    return target !== undefined ? target.title : '';
  }

  private sessionById(id: string): ChatSession | undefined {
    let i: number = 0;
    while (i < this.sessions.length) {
      if (this.sessions[i].id === id) {
        return this.sessions[i];
      }
      i += 1;
    }
    return undefined;
  }

  private sessActionIsPrivate(): boolean {
    const target: ChatSession | undefined = this.sessionById(this.sessActionId);
    return target !== undefined ? target.isPrivate : false;
  }

  /** 从历史抽屉打开会话：保密会话需先通过人脸/指纹认证。 */
  private async openSessionWithPrivacy(sess: ChatSession): Promise<void> {
    if (sess.isPrivate) {
      const ok: boolean = await AuthService.authenticate('解锁保密对话');
      if (!ok) {
        this.toast('身份验证未通过，无法打开该对话');
        return;
      }
    }
    await this.switchSession(sess.id);
  }

  /**
   * 切换会话保密标记。
   * Business Rule: 关闭保密必须重新通过人脸/指纹认证，否则可在不打开会话的前提下
   *   直接解除保密再打开，形成绕过路径；开启保密无需认证。
   */
  private async toggleSessPrivacy(): Promise<void> {
    const target: ChatSession | undefined = this.sessionById(this.sessActionId);
    if (target === undefined) {
      this.sessActionId = '';
      return;
    }
    if (target.isPrivate) {
      const ok: boolean = await AuthService.authenticate('取消保密需要验证身份');
      if (!ok) {
        this.toast('身份验证未通过');
        return;
      }
      target.isPrivate = false;
      this.toast('已取消保密');
    } else {
      target.isPrivate = true;
      this.toast('已设为保密会话，下次打开需验证身份');
    }
    this.sessActionId = '';
    this.rebuildSessionReference();
    await this.saveState();
  }

  private beginRename(): void {
    const title: string = this.sessActionTitle();
    if (title.length === 0) {
      this.sessActionId = '';
      return;
    }
    // 保留 sessActionId 作为重命名目标；菜单用 showRenameDialog 隐藏。
    this.renameText = title;
    this.showRenameDialog = true;
  }

  private cancelRename(): void {
    this.showRenameDialog = false;
    this.renameText = '';
    this.sessActionId = '';
  }

  private confirmRename(): void {
    const text: string = this.renameText.trim();
    if (text.length === 0) {
      return;
    }
    let i: number = 0;
    while (i < this.sessions.length) {
      if (this.sessions[i].id === this.sessActionId) {
        this.sessions[i].title = text;
        break;
      }
      i += 1;
    }
    this.showRenameDialog = false;
    this.renameText = '';
    this.sessActionId = '';
    this.rebuildSessionReference();
    this.saveState();
  }

  private askDeleteSession(): void {
    // 保留 sessActionId 作为删除目标；菜单用 showDeleteConfirm 隐藏。
    this.showDeleteConfirm = true;
  }

  private cancelDeleteSession(): void {
    this.showDeleteConfirm = false;
    this.sessActionId = '';
  }

  private async confirmDeleteSession(): Promise<void> {
    const id: string = this.sessActionId;
    this.showDeleteConfirm = false;
    this.sessActionId = '';
    if (id.length === 0) {
      return;
    }
    await this.deleteSession(id);
  }

  private openCharActions(id: string): void {
    this.charActionId = id;
  }

  private closeCharActions(): void {
    this.charActionId = '';
  }

  private charActionCard(): CharacterCard | undefined {
    let i: number = 0;
    while (i < this.characters.length) {
      if (this.characters[i].id === this.charActionId) {
        return this.characters[i];
      }
      i += 1;
    }
    return undefined;
  }

  private charActionName(): string {
    const c: CharacterCard | undefined = this.charActionCard();
    return c !== undefined ? c.name : '';
  }

  private editFromCharActions(): void {
    const c: CharacterCard | undefined = this.charActionCard();
    this.charActionId = '';
    if (c !== undefined) {
      this.openCharEdit(c);
    }
  }

  private askDeleteChar(): void {
    // 保留 charActionId 作为删除目标；菜单用 showCharDeleteConfirm 隐藏。
    this.showCharDeleteConfirm = true;
  }

  private cancelDeleteChar(): void {
    this.showCharDeleteConfirm = false;
    this.charActionId = '';
  }

  private async confirmDeleteChar(): Promise<void> {
    const id: string = this.charActionId;
    this.showCharDeleteConfirm = false;
    this.charActionId = '';
    if (id.length === 0) {
      return;
    }
    const kept: CharacterCard[] = [];
    let i: number = 0;
    while (i < this.characters.length) {
      if (this.characters[i].id !== id) {
        kept.push(this.characters[i]);
      }
      i += 1;
    }
    this.characters = kept;
    if (this.currentCharacterId === id) {
      this.currentCharacterId = '';
      const cur: ChatSession | undefined = this.getCurrentSession();
      if (cur) {
        cur.characterId = '';
      }
    }
    await ChatStorageService.saveCharacters(this.characters);
    this.rebuildSessionReference();
    await this.saveState();
  }

  // ── 发送与流式输出 ──

  private rebuildSessionReference(): void {
    const list: ChatSession[] = [];
    let i: number = 0;
    while (i < this.sessions.length) {
      list.push(this.sessions[i]);
      i += 1;
    }
    this.sessions = list;
    this.syncMessageSource();
  }

  /**
   * 单条消息的渲染键：ForEach 时代决定同 key 复用旧快照、异 key 重建；
   * LazyForEach 时代同时作为数据源增量刷新的判据（见 ChatMessageDataSource.sync）。
   * Business Rule: 有正文后恒为 'C' 稳定实例，流式增量交给 MarkdownController，不重建防闪。
   */
  private msgRenderKey(msg: ChatMessage): string {
    const collapsed: string = this.isReasonCollapsed(msg.id) ? 'c' : 'e';
    // 来源胶囊展开态、朗读态都是页面级 @State：必须进 key，否则 LazyForEach 复用旧快照，
    // 点开展开/打断朗读按钮的高亮都不会变化。
    const expanded: string = this.expandedSourceMsgId === msg.id ? 'X' : '-';
    const reading: string = this.readingMsgId === msg.id ? 'R' : '-';
    // 生图态与图片数量进 key：状态从 generating 变 done 时必须重建该条。
    const img: string = `${msg.imageState !== undefined ? msg.imageState : '-'}${msg.imageUrls !== undefined ? msg.imageUrls.length : 0}`;
    return `${msg.id}_${msg.status}_${collapsed}_${expanded}_${reading}_${img}_${Math.round(this.appFontScale * 100)}_${this.appDark ? 'd' : 'l'}_${this.msgContentPhaseKey(msg)}`;
  }

  /** 把当前激活分支与渲染键推给 LazyForEach 数据源（结构性/局部刷新由数据源内部判定）。 */
  private syncMessageSource(): void {
    const path: ChatMessage[] = this.activePath();
    const keys: string[] = [];
    let i: number = 0;
    while (i < path.length) {
      keys.push(this.msgRenderKey(path[i]));
      i += 1;
    }
    this.msgSource.sync(path, keys);
  }

  // ── Markdown 渲染接入（FluidMarkdown） ──

  private isDarkMode(): boolean {
    return this.appDark;
  }

  /**
   * Reason: ForEach 同 key 会复用旧快照不刷新，流式期必须让相关条目重建。
   *   正文未出现前把思考字数纳入 key（'R<n>'），使思考文本随 token 逐帧刷新
   *   （此时 MarkdownBody 尚未挂载，重建无副作用）；正文一旦出现即切换为固定的 'C'，
   *   key 从此稳定，MarkdownBody 只挂载一次、后续增量由 controller 驱动（不重建防闪）。
   * Business Rule: 有正文后思考内容按约定冻结，key 不再随思考长度变化。
   */
  private msgContentPhaseKey(msg: ChatMessage): string {
    if (msg.content.length > 0) {
      return 'C';
    }
    const rLen: number = msg.reasoningContent ? msg.reasoningContent.length : 0;
    // 联网搜索过程：正文出现前把搜索态与来源数纳入 key，进度提示与来源卡片才能逐帧刷新；
    // 正文出现后仍切回 'C'，不破坏「MarkdownBody 只挂载一次」的稳定实例约定。
    const srcCount: number = msg.sources !== undefined ? msg.sources.length : 0;
    if (msg.searchState !== undefined || srcCount > 0) {
      const hintLen: number = msg.searchHint !== undefined ? msg.searchHint.length : 0;
      return `R${rLen}S${msg.searchState === 'searching' ? '1' : '0'}${srcCount}H${hintLen}`;
    }
    return rLen > 0 ? `R${rLen}` : 'E';
  }

  /** 正文未出时的状态文案：搜索过程提示优先于「思考中」，避免联网时长时间无反馈。 */
  private generationHint(msg: ChatMessage): string {
    if (msg.searchHint !== undefined && msg.searchHint.length > 0) {
      return msg.searchHint;
    }
    return '思考中...';
  }

  /** 来源列表（@Builder 内不做空值判断，统一由这里给空数组兜底）。 */
  private sourcesOf(msg: ChatMessage): SearchSource[] {
    return msg.sources !== undefined ? msg.sources : [];
  }

  /** 正文渲染内容：流式中只做 [ref_N] 改写；完成后按引用位标插入可点角标。 */
  private renderContent(msg: ChatMessage): string {
    if (this.isLiveStreaming(msg)) {
      return MarkdownService.rewriteCitations(msg.content);
    }
    return MarkdownService.rewriteCitations(
      MarkdownService.injectCitations(msg.content, msg.citations, this.citeIndexMap(msg)));
  }

  /** url -> 来源序号（1 起）。序号顺序必须与来源列表一致，角标才能点对卡片。 */
  private citeIndexMap(msg: ChatMessage): Map<string, number> {
    const map: Map<string, number> = new Map();
    const list: SearchSource[] = this.sourcesOf(msg);
    let i: number = 0;
    while (i < list.length) {
      if (!map.has(list[i].url)) {
        map.set(list[i].url, i + 1);
      }
      i += 1;
    }
    return map;
  }

  /** 胶囊上最多显示 3 个站点图标（官方 App 同款堆叠）。 */
  private pillSources(msg: ChatMessage): SearchSource[] {
    const list: SearchSource[] = this.sourcesOf(msg);
    const out: SearchSource[] = [];
    let i: number = 0;
    while (i < list.length && out.length < 3) {
      out.push(list[i]);
      i += 1;
    }
    return out;
  }

  private toggleSourcePanel(msgId: string): void {
    this.expandedSourceMsgId = this.expandedSourceMsgId === msgId ? '' : msgId;
    // 展开态已进渲染键，需推一次数据源才会重建该条（LazyForEach 同 key 复用旧快照）。
    this.syncMessageSource();
  }

  /**
   * 朗读/停止朗读一条回复。
   * Business Rule: 语音合成是 DeepSeek 专属能力，Key 取 key_deepseek（与当前服务商无关），
   *   没有 DeepSeek Key 时直接提示去资产监控配置，不发起请求。
   */
  private async toggleReadAloud(msg: ChatMessage): Promise<void> {
    if (this.readingMsgId === msg.id) {
      this.stopReadAloud();
      return;
    }
    if (msg.content.trim().length === 0) {
      this.toast('暂无内容可朗读');
      return;
    }
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const key: string = await SettingsService.getProviderKey(hostCtx, 'deepseek');
    if (key.trim().length === 0) {
      this.toast('请先在「设置 > 资产监控」配置 DeepSeek API Key');
      return;
    }
    const voice: string = await SettingsService.getTtsVoice(hostCtx);
    this.stopReadAloud();
    this.readingMsgId = msg.id;
    // 朗读态进渲染键，按钮高亮/可打断状态需要该条重建。
    this.syncMessageSource();
    const callbacks: TtsCallbacks = {
      onStart: () => {
      },
      onFinish: () => {
        this.readingMsgId = '';
        this.syncMessageSource();
      },
      onError: (message: string) => {
        this.readingMsgId = '';
        this.syncMessageSource();
        this.toast(message);
      }
    };
    await TtsService.speak(hostCtx, { apiKey: key, text: msg.content, voiceId: voice }, callbacks);
  }

  private stopReadAloud(): void {
    const wasReading: boolean = this.readingMsgId.length > 0;
    TtsService.stopPlayback();
    this.readingMsgId = '';
    if (wasReading) {
      this.syncMessageSource();
    }
  }

  private isReading(msgId: string): boolean {
    return this.readingMsgId === msgId;
  }

  /** 当前分支上最后一条有正文的助手回答（顶栏喇叭读它）。 */
  private lastAnswer(): ChatMessage | undefined {
    const path: ChatMessage[] = this.activePath();
    let i: number = path.length - 1;
    while (i >= 0) {
      const m: ChatMessage = path[i];
      if (m.role === 'assistant' && m.content.trim().length > 0) {
        return m;
      }
      i -= 1;
    }
    return undefined;
  }

  /** 顶栏喇叭：朗读最后一条回答；正在朗读时再点即停止。 */
  private async readLastAnswer(): Promise<void> {
    const msg: ChatMessage | undefined = this.lastAnswer();
    if (msg === undefined) {
      this.toast('还没有可朗读的回答');
      return;
    }
    await this.toggleReadAloud(msg);
  }

  /** 顶栏写消息：新建会话并直接进入角色选择（与抽屉「+ 新会话」同一流程）。 */
  private startNewChat(): void {
    this.createNewSession();
    this.pendingParticipants = [];
    this.characterSheetMode = 'select';
    this.showCharacterSheet = true;
  }

  /** 仅当消息仍在流式且驱动器存活时走 Typing；否则一律 Normal（防僵尸流式）。 */
  private isLiveStreaming(msg: ChatMessage): boolean {
    return msg.status === 'streaming' && this.mdControllers.has(msg.id);
  }

  /** 思考区内嵌 Scroller（懒建随消息 id 存活，删会话时清理，防泄漏）。 */
  private thinkScrollerFor(id: string): Scroller {
    const existed: Scroller | undefined = this.thinkScrollers.get(id);
    if (existed !== undefined) {
      return existed;
    }
    const created: Scroller = new Scroller();
    this.thinkScrollers.set(id, created);
    return created;
  }

  /**
   * 思考区跟底：仅当内滚动已在底部时跟随（用户上翻查看旧思考时不动，
   *   否则就是外层锚定"拽回" bug 在小框里的重演）。
   */
  private followThinking(msgId: string): void {
    const sc: Scroller | undefined = this.thinkScrollers.get(msgId);
    if (sc === undefined) {
      return;
    }
    try {
      // Reason: 思考文本经 LazyForEach 渲染键（R<n>）变化会重建条目，内嵌 Scroll 的滚动位置随之重置，
      //   isAtEnd() 判断会误判为"不在底部"而放弃跟随，导致长思考沉底不可见。
      //   生成期间（本方法仅在 onToken 路径被调）统一贴底即可；生成结束不再调用，用户可自由翻阅。
      sc.scrollEdge(Edge.Bottom);
    } catch (_e) {
    }
  }

  /** 库 Typing 就绪：只记标记，Begin 由下一拍 driveMarkdown 用累计文本发出（无损）。 */
  private onMarkdownReady(msgId: string): void {
    // 完成/停止后 controller 已删，天然忽略迟到就绪。
    if (this.mdControllers.has(msgId) && !this.mdTypingReady.includes(msgId)) {
      this.mdTypingReady.push(msgId);
    }
  }

  /**
   * 流式刷新节流（~8fps）：driveMarkdown + 整表重建 + 思考跟随统一压到 tick。
   * Reason: token 可达百 Hz，直驱全表重建会压垮 UI 线程致刷新合并成"一次性"；
   *   喂给库的永远是累计文本，合并无损。完成/停止走直接重建，不经此门。
   */
  private refreshStreamView(msg: ChatMessage): void {
    const now: number = Date.now();
    if (now - this.lastRefreshAt < 120) {
      if (!this.refreshPending) {
        this.refreshPending = true;
        const targetId: string = msg.id;
        setTimeout(() => {
          this.refreshPending = false;
          this.lastRefreshAt = Date.now();
          const target: ChatMessage | undefined = this.findLiveMessage(targetId);
          if (target !== undefined) {
            this.driveMarkdown(target);
          }
          this.rebuildSessionReference();
          this.followThinking(targetId);
        }, 120);
      }
      return;
    }
    this.lastRefreshAt = now;
    this.driveMarkdown(msg);
    this.rebuildSessionReference();
    this.followThinking(msg.id);
  }

  /** 跨会话按 id 找存活消息（节流 tick 触发时原对象引用仍有效，此为兜底）。 */
  private findLiveMessage(id: string): ChatMessage | undefined {
    let si: number = 0;
    while (si < this.sessions.length) {
      const sess: ChatSession = this.sessions[si];
      let mi: number = 0;
      while (mi < sess.messages.length) {
        if (sess.messages[mi].id === id) {
          return sess.messages[mi];
        }
        mi += 1;
      }
      si += 1;
    }
    return undefined;
  }
  private driveMarkdown(msg: ChatMessage): void {
    // 库契约：update 只能在 TypingReady 之后；就绪前跳过（不记 begun），就绪后首帧即 Begin。
    if (!this.mdTypingReady.includes(msg.id)) {
      return;
    }
    const ctl: MarkdownController | undefined = this.mdControllers.get(msg.id);
    if (ctl === undefined) {
      return;
    }
    const full: string = MarkdownService.rewriteCitations(msg.content);
    try {
      if (!this.mdTypingBegun.includes(msg.id)) {
        this.mdTypingBegun.push(msg.id);
        ctl.typing.update(full, ETypingMode.Begin, true);
      } else {
        ctl.typing.update(full, ETypingMode.Append, true);
      }
    } catch (_e) {
    }
  }

  /** 收尾：正常结束刷 End 帧吐完 pacing 队列；中断则直接停。随后删驱动器防泄漏。 */
  private finishMarkdown(msg: ChatMessage, stopped: boolean): void {
    const ctl: MarkdownController | undefined = this.mdControllers.get(msg.id);
    // 未 Begin（就绪前即完成）则不发 End，无会话可收尾。
    if (ctl !== undefined && !stopped && this.mdTypingBegun.includes(msg.id)) {
      try {
        ctl.typing.update(this.renderContent(msg), ETypingMode.End, false);
      } catch (_e) {
      }
    }
    this.mdControllers.delete(msg.id);
    this.mdTypingReady = this.withoutId(this.mdTypingReady, msg.id);
    this.mdTypingBegun = this.withoutId(this.mdTypingBegun, msg.id);
  }

  private withoutId(list: string[], id: string): string[] {
    const kept: string[] = [];
    let i: number = 0;
    while (i < list.length) {
      if (list[i] !== id) {
        kept.push(list[i]);
      }
      i += 1;
    }
    return kept;
  }

  private dropSessionControllers(sess: ChatSession): void {
    let i: number = 0;
    while (i < sess.messages.length) {
      const id: string = sess.messages[i].id;
      this.mdControllers.delete(id);
      this.thinkScrollers.delete(id);
      i += 1;
    }
    const kept: string[] = [];
    let j: number = 0;
    while (j < this.mdTypingBegun.length) {
      if (!this.mdControllers.has(this.mdTypingBegun[j])) {
        // 已删驱动的 begun 标记一并清理（has 判空，无额外查找）。
      } else {
        kept.push(this.mdTypingBegun[j]);
      }
      j += 1;
    }
    this.mdTypingBegun = kept;
    const keptReady: string[] = [];
    let k: number = 0;
    while (k < this.mdTypingReady.length) {
      if (this.mdControllers.has(this.mdTypingReady[k])) {
        keptReady.push(this.mdTypingReady[k]);
      }
      k += 1;
    }
    this.mdTypingReady = keptReady;
  }

  private onMarkdownLink(href: string, msg?: ChatMessage): void {
    const action: MdClickAction = MarkdownService.routeHref(href);
    if (action.kind === 'cite') {
      // 引用角标按序号映射到该条消息的 sources（1 起）；无来源时不再假装可点。
      const sources: SearchSource[] = msg !== undefined && msg.sources !== undefined ? msg.sources : [];
      const at: number = action.index - 1;
      if (at >= 0 && at < sources.length) {
        hilog.info(DOMAIN, TAG, 'citation opened: %{public}d', action.index);
        this.openExternalUrl(sources[at].url);
        return;
      }
      this.toast(`引用来源 [${action.index}] 不在来源列表中`);
      return;
    }
    if (action.kind === 'open') {
      this.openExternalUrl(action.target);
      return;
    }
    this.toast('该链接暂不支持打开');
    hilog.warn(DOMAIN, TAG, 'blocked unsafe link');
  }

  private onMarkdownImage(src: string): void {
    this.previewImage = src;
  }

  private async openExternalUrl(url: string): Promise<void> {
    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await hostCtx.startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url,
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'open url failed: %{public}s', String(err));
      this.toast('无法打开链接');
    }
  }

  private canSend(): boolean {
    if (this.currentApiKey.trim().length === 0) {
      this.noticeText = `未配置 [${this.getProviderName(this.currentProviderId)}] 的 API Key，请先在设置中添加`;
      return false;
    }
    if (this.currentModelId.trim().length === 0 || this.currentModelId === '选择模型') {
      this.noticeText = '请先点击右上角选择一个有效模型';
      return false;
    }
    return true;
  }

  private currentLeafId(sess: ChatSession): string {
    const path: ChatMessage[] = this.activePath();
    return path.length > 0 ? path[path.length - 1].id : '';
  }

  /**
   * 本地兜底标题：取用户消息前 14 字。
   * Business Rule: 服务端标题可能缺失（拒答/出错），且只在本轮返回一次；
   *   因此发送时就先写一个兜底标题，拿到服务端标题再覆盖。
   */
  private defaultTitleFor(text: string): string {
    const trimmed: string = text.trim();
    return trimmed.length > 14 ? `${trimmed.substring(0, 14)}...` : trimmed;
  }

  /** 当前分支上第一条用户消息（用于判断标题是否仍为自动生成）。 */
  private firstUserText(): string {
    const path: ChatMessage[] = this.activePath();
    let i: number = 0;
    while (i < path.length) {
      if (path[i].role === 'user') {
        return path[i].content;
      }
      i += 1;
    }
    return '';
  }

  /** 标题是否仍为自动生成（用户手动重命名过就不再让服务端覆盖）。 */
  private isAutoTitle(sess: ChatSession): boolean {
    return sess.title === '新对话' || sess.title === this.defaultTitleFor(this.firstUserText());
  }

  /** 输入框里已就绪（拿到 file_id）的附件。 */
  /** 附件缩略图路径（无预览副本时返回 ''，调用方按 if 判断，不要直接传可选类型）。 */
  private attachThumb(att: MessageAttachment): string {
    return att.localUri !== undefined ? att.localUri : '';
  }

  /**
   * 图片源归一化：应用沙箱里的绝对路径必须补 `file://` 前缀，否则 Image 静默加载失败（只剩占位空白）。
   * 已在 assets/网络 URL 上的原样返回。
   */
  private imageSrc(path: string): string {
    if (path.length === 0) {
      return '';
    }
    if (path.startsWith('file://') || path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    return `file://${path}`;
  }

  private readyAttachments(): MessageAttachment[] {
    const out: MessageAttachment[] = [];
    let i: number = 0;
    while (i < this.pendingFiles.length) {
      const pf: PendingFile = this.pendingFiles[i];
      i += 1;
      if (pf.status === 'ready' && pf.fileId.length > 0) {
        const att: MessageAttachment = {
          fileId: pf.fileId,
          fileName: pf.fileName,
          purpose: pf.purpose,
          bytes: pf.bytes,
          localUri: pf.localUri
        };
        out.push(att);
      }
    }
    return out;
  }

  private hasUploadingFile(): boolean {
    let i: number = 0;
    while (i < this.pendingFiles.length) {
      if (this.pendingFiles[i].status === 'uploading') {
        return true;
      }
      i += 1;
    }
    return false;
  }

  /**
   * 选文件 → 上传解析 → 进入待发送列表。
   * Business Rule: 文件接口是 DeepSeek 专属，且解析完成才拿到 file_id；
   *   解析期间不允许发送（见 sendMessage），失败只提示、不占位。
   */
  /** 附件入口的前置校验：服务商/Key/数量，返回可用的 DeepSeek Key（'' 表示已提示过、不继续）。 */
  private async resolveAttachKey(): Promise<string> {
    if (!this.featureFiles) {
      this.toast('文件解析已在「设置 > 工具」关闭');
      return '';
    }
    if (this.currentProviderId !== 'deepseek') {
      this.toast('文件与图片输入目前仅支持 DeepSeek');
      return '';
    }
    if (this.pendingFiles.length >= 3) {
      this.toast('一次最多添加 3 个文件');
      return '';
    }
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const key: string = await SettingsService.getProviderKey(hostCtx, 'deepseek');
    if (key.trim().length === 0) {
      this.toast('请先在「设置 > 资产监控」配置 DeepSeek API Key');
      return '';
    }
    return key;
  }

  /** 拍照：系统相机 UI，不需要应用申请相机权限。 */
  private async attachFromCamera(): Promise<void> {
    this.showAttachSheet = false;
    const key: string = await this.resolveAttachKey();
    if (key.length === 0) {
      return;
    }
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const uri: string = await FileUploadService.capturePhoto(hostCtx);
    if (uri.length === 0) {
      return;
    }
    await this.uploadAttachments([uri], key);
  }

  /** 相册：系统图库选择器，可多选，最多补满 3 个。 */
  private async attachFromGallery(): Promise<void> {
    this.showAttachSheet = false;
    const key: string = await this.resolveAttachKey();
    if (key.length === 0) {
      return;
    }
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const room: number = 3 - this.pendingFiles.length;
    const uris: string[] = await FileUploadService.pickImages(hostCtx, room);
    await this.uploadAttachments(uris, key);
  }

  /** 文件：系统文件选择器（PDF/Office/文本等）。 */
  private async attachFromFiles(): Promise<void> {
    this.showAttachSheet = false;
    const key: string = await this.resolveAttachKey();
    if (key.length === 0) {
      return;
    }
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const uri: string = await FileUploadService.pick(hostCtx);
    if (uri.length === 0) {
      return;
    }
    await this.uploadAttachments([uri], key);
  }

  /**
   * 逐个上传（串行，避免同时占满服务端 15 路上传配额）。
   * Business Rule: 解析完成才拿到 file_id；失败只移除该条并提示，不影响其它文件。
   */
  private async uploadAttachments(uris: string[], key: string): Promise<void> {
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let i: number = 0;
    while (i < uris.length) {
      if (this.pendingFiles.length >= 3) {
        this.toast('一次最多添加 3 个文件');
        return;
      }
      const uri: string = uris[i];
      i += 1;
      const fileName: string = FileUploadService.nameFromUri(uri);
      const purpose: string = FileUploadService.purposeFor(fileName);
      if (purpose.length === 0) {
        this.toast(`暂不支持该格式：${fileName}`);
        continue;
      }
      const pending: PendingFile = {
        fileName: fileName,
        purpose: purpose,
        status: 'uploading',
        fileId: '',
        bytes: 0,
        // 选图当下就落一份沙箱副本：气泡缩略图要用，picker URI 不能长期引用。
        localUri: FileUploadService.persistForPreview(hostCtx, uri, fileName)
      };
      this.pendingFiles = this.pendingFiles.concat([pending]);

      try {
        const up: UploadedFile = await FileUploadService.upload(hostCtx, uri, key, purpose);
        const next: PendingFile[] = [];
        let pi: number = 0;
        while (pi < this.pendingFiles.length) {
          const cur: PendingFile = this.pendingFiles[pi];
          pi += 1;
          if (cur === pending) {
            const ready: PendingFile = {
              fileName: up.fileName,
              purpose: up.purpose,
              status: 'ready',
              fileId: up.fileId,
              bytes: up.bytes,
              localUri: pending.localUri
            };
            next.push(ready);
          } else {
            next.push(cur);
          }
        }
        this.pendingFiles = next;
      } catch (err) {
        const remain: PendingFile[] = [];
        let ri: number = 0;
        while (ri < this.pendingFiles.length) {
          const cur: PendingFile = this.pendingFiles[ri];
          ri += 1;
          if (cur !== pending) {
            remain.push(cur);
          }
        }
        this.pendingFiles = remain;
        const reason: string = err instanceof Error ? err.message : String(err);
        this.toast(`上传失败：${reason}`);
      }
    }
  }

  private removePendingFile(target: PendingFile): void {
    const remain: PendingFile[] = [];
    let i: number = 0;
    while (i < this.pendingFiles.length) {
      const cur: PendingFile = this.pendingFiles[i];
      i += 1;
      if (cur !== target) {
        remain.push(cur);
      }
    }
    this.pendingFiles = remain;
  }

  /**
   * 是否显示「展开/收起」角标：只有内容超过一行（约 18 个字或带换行）或已展开时才出现。
   * Reason: 官方输入框平时没有这个按钮，空间留给文字；内容长了再给一个放大入口。
   */
  private showExpandToggle(): boolean {
    if (this.inputExpanded) {
      return true;
    }
    const text: string = this.inputText;
    return text.length > 18 || text.includes('\n');
  }

  /** 输入框是否已有可发送内容（文字或已就绪附件）：决定右侧显示发送还是麦克风。 */
  private hasSendableInput(): boolean {
    return this.inputText.trim().length > 0 || this.readyAttachments().length > 0;
  }

  private async ensureMicPermission(): Promise<boolean> {
    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(hostCtx, ['ohos.permission.MICROPHONE']);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'mic permission failed: %{public}s', String(err));
      return false;
    }
  }

  private recordTimeText(): string {
    const minutes: number = Math.floor(this.recordSeconds / 60);
    const seconds: number = this.recordSeconds % 60;
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
  }

  private startRecordTimer(): void {
    this.clearRecordTimer();
    this.recordTimer = setInterval(() => {
      this.recordSeconds += 1;
      if (this.recordSeconds >= 120) {
        this.finishRecording();
      }
    }, 1000);
  }

  private clearRecordTimer(): void {
    if (this.recordTimer >= 0) {
      clearInterval(this.recordTimer);
      this.recordTimer = -1;
    }
  }

  /** 进入语音模式：输入区整体变成「按住说话」。 */
  private enterVoiceMode(): void {
    if (this.isGenerating || this.transcribing) {
      return;
    }
    this.voiceMode = true;
    this.recordSeconds = 0;
  }

  /** 退出语音模式（切回键盘输入）：录音中先丢弃。 */
  private exitVoiceMode(): void {
    if (this.recording) {
      this.abortRecording();
    }
    this.voiceMode = false;
  }

  /** 按住说话：按下开始录音，抬起/取消结束并转写。 */
  private async onHoldTouch(event: TouchEvent): Promise<void> {
    if (event.type === TouchType.Down) {
      if (this.recording || this.transcribing) {
        return;
      }
      this.holdDown = true;
      await this.beginHoldRecord();
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.holdDown = false;
      if (this.recording) {
        await this.finishRecording();
      }
    }
  }

  private async beginHoldRecord(): Promise<void> {
    if (this.recording || this.transcribing) {
      return;
    }
    const granted: boolean = await this.ensureMicPermission();
    if (!granted) {
      this.toast('需要麦克风权限才能语音输入');
      return;
    }
    // 授权弹窗期间可能已松手：不再启动录音。
    if (!this.holdDown) {
      return;
    }
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const started: boolean = await VoiceRecorder.start(hostCtx);
    if (!started) {
      this.toast('无法启动录音');
      return;
    }
    this.recording = true;
    this.recordSeconds = 0;
    if (!this.holdDown) {
      // 录音启动前手指就离开了：立即收尾，避免录音一直跑。
      await this.finishRecording();
      return;
    }
    this.startRecordTimer();
  }

  /** 结束录音并转写：文本回填输入框但不自动发送，留给用户确认/修改。 */
  private async finishRecording(): Promise<void> {
    if (!this.recording) {
      return;
    }
    this.recording = false;
    this.clearRecordTimer();
    this.transcribing = true;
    try {
      const path: string = await VoiceRecorder.stop();
      if (path.length === 0) {
        this.toast('录音失败，请重试');
        return;
      }
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const key: string = await SettingsService.getProviderKey(hostCtx, 'deepseek');
      if (key.trim().length === 0) {
        this.toast('请先在「设置 > 资产监控」配置 DeepSeek API Key');
        return;
      }
      const text: string = await AsrService.transcribe(hostCtx, path, key);
      if (text.length === 0) {
        this.toast('没有识别到语音');
        return;
      }
      const existing: string = this.inputText;
      this.inputText = existing.trim().length > 0 ? `${existing} ${text}` : text;
      // 转写成功即切回文字模式，右侧变发送钮，交由用户确认后发送。
      this.voiceMode = false;
    } catch (err) {
      const reason: string = err instanceof Error ? err.message : String(err);
      this.toast(`语音识别失败：${reason}`);
    } finally {
      this.transcribing = false;
    }
  }

  /** 放弃录音（离开页面等）：停录并删除临时音频。 */
  private abortRecording(): void {
    if (!this.recording) {
      return;
    }
    this.recording = false;
    this.clearRecordTimer();
    VoiceRecorder.cancel();
  }

  private async sendMessage(): Promise<void> {
    const text: string = this.inputText.trim();
    if (this.isGenerating) {
      return;
    }
    if (this.hasUploadingFile()) {
      this.toast('文件正在解析，请稍候');
      return;
    }
    const attachments: MessageAttachment[] = this.readyAttachments();
    if (text.length === 0 && attachments.length === 0) {
      return;
    }

    const sess: ChatSession | undefined = this.getCurrentSession();
    if (!sess) {
      return;
    }
    if (!this.canSend()) {
      return;
    }

    this.inputText = '';
    this.inputExpanded = false;
    this.noticeText = '';

    if (sess.title === '新对话') {
      sess.title = text.length > 0 ? this.defaultTitleFor(text) : this.defaultTitleFor(attachments[0].fileName);
    }

    // 新消息挂在当前激活分支的叶节点之下；@ 以选择器+文本扫描双通道校对后落库。
    const parentId: string = this.currentLeafId(sess);
    const userMsg: ChatMessage = this.buildMessage('user', text, parentId);
    if (attachments.length > 0) {
      userMsg.attachments = attachments;
      this.pendingFiles = [];
    }
    let mi: number = 0;
    while (mi < this.pendingMentions.length) {
      const mid: string = this.pendingMentions[mi];
      const mName: string = this.characterName(mid);
      if (mName.length > 0 && text.includes(`@${mName}`)) {
        userMsg.mentionedIds.push(mid);
      }
      mi += 1;
    }
    if (sess.sceneMode === 'group') {
      const scanned: string[] = this.extractMentions(sess, text);
      let si: number = 0;
      while (si < scanned.length) {
        if (!userMsg.mentionedIds.includes(scanned[si])) {
          userMsg.mentionedIds.push(scanned[si]);
        }
        si += 1;
      }
    }
    this.pendingMentions = [];
    this.attach(sess, userMsg);
    sess.updatedAt = Date.now();
    this.rebuildSessionReference();
    this.scrollToBottom();

    // [群聊下线已注释] 无群聊模式，一律走单聊生成
    /*
    if (sess.sceneMode === 'group' && sess.participantIds.length > 0) {
      this.isGenerating = true;
      try {
        await this.sendGroup(sess, userMsg);
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'sendGroup failed: %{public}s', String(err));
      } finally {
        this.isGenerating = false;
        this.rebuildSessionReference();
      }
      return;
    }
    */
    this.generateReply(sess, userMsg, this.getCurrentCharacter());
  }

  /* [群聊下线已注释]
  private async sendGroup(sess: ChatSession, userMsg: ChatMessage): Promise<void> {
    // 群聊路由与链式生成代码已下线
  }
  */

  /** 为 parentMsg 挂 assistant 占位并流式生成；历史取根->parentMsg 的分支路径。 */
  private async generateReply(sess: ChatSession, parentMsg: ChatMessage, speaker: CharacterCard): Promise<void> {
    // 百智云联网搜索：发送前先检索，把摘要注入系统提示、来源挂到本条消息。
    // Business Rule: 检索失败降级为普通回答（toast 提示），绝不阻塞对话。
    let webContext: string = '';
    let preSources: SearchSource[] = [];
    if (this.enableWebSearch && this.webSearchProvider === WEB_SEARCH_PROVIDER_BAIZHI) {
      try {
        const searchCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const webKey: string = await SettingsService.getBaizhiWebKey(searchCtx);
        if (webKey.trim().length === 0) {
          throw new Error('未配置百智云搜索 Key（设置 > 工具）');
        }
        const query: string = parentMsg.content.trim();
        if (query.length > 0) {
          const results: SearchSource[] = await BaizhiWebSearchService.search(query, webKey, 8);
          if (results.length > 0) {
            preSources = results;
            webContext = BaizhiWebSearchService.buildContextMessage(results);
          }
        }
      } catch (err) {
        const reason: string = err instanceof Error ? err.message : String(err);
        this.toast('联网搜索失败，改为普通回答：' + reason);
      }
    }
    return new Promise<void>((resolve: () => void) => {
      const assistantMsg: ChatMessage = this.buildMessage('assistant', '', parentMsg.id);
      assistantMsg.status = 'streaming';
      assistantMsg.speakerId = speaker.id;
      if (preSources.length > 0) {
        assistantMsg.sources = WebSearchService.mergeSources(assistantMsg.sources, preSources);
      }
      this.attach(sess, assistantMsg);
      sess.updatedAt = Date.now();
      this.rebuildSessionReference();
      this.isGenerating = true;
      // 新一轮生成：重置锚定，先跟随到底，再由锚定逻辑把首行推顶（首 token 到达时一次性执行）。
      this.userTookOver = false;
      this.showJumpBottom = false;
      this.anchorCaptured = false;
      this.anchoredForMsgId = '';
      this.reasonChunkCount = 0;
      this.contentChunkCount = 0;
      this.lastRefreshAt = 0;
      this.refreshPending = false;
      this.scrollToBottom();

      const finish = (): void => {
        this.resolveCurrent = undefined;
        resolve();
      };
      this.resolveCurrent = finish;

      // Reason: 历史仅取该分支路径（historyTo 沿 parent 链），编辑/切分支后互不污染。
      const rawHistory: ChatMessage[] = this.historyTo(sess, parentMsg.id);
      const history: ChatMessage[] = [];

      let hi: number = 0;
      while (hi < rawHistory.length) {
        const h: ChatMessage = rawHistory[hi];
        const content: string = h.content;
        const tagged: ChatMessage = {
          id: h.id,
          role: h.role,
          content: content,
          reasoningContent: h.reasoningContent,
          createdAt: h.createdAt,
          status: h.status,
          errorMessage: h.errorMessage,
          parentId: h.parentId,
          childIds: [],
          activeChildId: h.activeChildId,
          speakerId: h.speakerId,
          mentionedIds: [],
          // 文档附件必须随历史回传，否则追问会丢上下文（服务端靠 file_id 还原文档）。
          attachments: h.attachments,
          // 阅读链接的 signature 同样必须原样回传，否则下一轮读不到旧网页。
          serverToolCallsJson: h.serverToolCallsJson,
        };
        history.push(tagged);
        hi += 1;
      }

      const thinkingStartTime: number = Date.now();
      let thinkingEndTime: number = 0;

      // 流式 Markdown 驱动器：随本轮回复创建，随完成/失败/停止销毁。
      const mdCtl: MarkdownController = new MarkdownController({});
      this.mdControllers.set(assistantMsg.id, mdCtl);

      // 本轮模型可能发起的客户端工具调用（generate_image），流结束后统一执行。
      let roundToolCalls: ToolCallRequest[] = [];

      const callbacks: StreamCallbacks = {
        onToken: (token: string, reasoningChunk?: string) => {
          if (reasoningChunk && reasoningChunk.length > 0) {
            assistantMsg.reasoningContent = (assistantMsg.reasoningContent || '') + reasoningChunk;
            this.reasonChunkCount += 1;
            // 思考生成中：确保不处于折叠状态，保持展开
            const cIdx: number = this.collapsedReasons.indexOf(assistantMsg.id);
            if (cIdx >= 0) {
              this.collapsedReasons.splice(cIdx, 1);
            }
            // 思考跟随在节流 tick 内统一做（refreshStreamView），此处只做数据追加。
          }
          if (token && token.length > 0) {
            this.contentChunkCount += 1;
            if (thinkingEndTime === 0 && assistantMsg.reasoningContent && assistantMsg.reasoningContent.length > 0) {
              thinkingEndTime = Date.now();
              const elapsedSec: number = Math.max(1, Math.round((thinkingEndTime - thinkingStartTime) / 1000));
              assistantMsg.thinkingDuration = elapsedSec;
              // 思考完毕，正文开始：自动折叠为已思考
              // Reason: 折叠态进入单条消息渲染键；下面的流式刷新同步数据源后只更新此消息项。
              if (this.autoCollapseThinking) {
                if (!this.collapsedReasons.includes(assistantMsg.id)) {
                  this.collapsedReasons.push(assistantMsg.id);
                }
              }
            }
            assistantMsg.content += token;
          }
          // 高频刷新节流：driveMarkdown/重建/跟随统一压到 tick（~8fps），累计文本无损。
          this.refreshStreamView(assistantMsg);
          // 顶部锚定：首 token 把回答首行推到容器顶部即停住（单条只一次），而非持续跟底。
          this.scheduleAnchor(assistantMsg.id);
        },
        onSearch: (progress: SearchProgress) => {
          // 诊断用：只记工具类型与动作，不记关键词（可能含用户输入）。
          hilog.info(DOMAIN, TAG, 'tool %{public}s kind=%{public}s action=%{public}s sources=%{public}d failed=%{public}s error=%{public}s',
            progress.phase, progress.kind, progress.action, progress.sources.length,
            String(progress.failed), progress.errorCode !== undefined ? progress.errorCode : '-');
          assistantMsg.searchState = progress.phase === 'started' ? 'searching' : 'done';
          if (progress.sources.length > 0) {
            assistantMsg.sources = WebSearchService.mergeSources(assistantMsg.sources, progress.sources);
          }
          const count: number = assistantMsg.sources !== undefined ? assistantMsg.sources.length : 0;
          if (progress.phase === 'started') {
            assistantMsg.searchHint = WebSearchService.startedLabel(progress);
          } else if (progress.failed && (progress.action === 'read_link' || progress.kind === 'read_link')) {
            // 阅读链接失败（链接不可达或被内容安全拦截）：给明确失败提示，别停在「正在阅读」。
            assistantMsg.searchHint = '链接读取失败，继续整理答案…';
          } else {
            assistantMsg.searchHint = WebSearchService.searchedLabel(count);
          }
          // 与 token 走同一节流刷新：预正文阶段 searchState/来源数已进渲染键，提示与卡片才能出现。
          this.refreshStreamView(assistantMsg);
        },
        onCitations: (citations: CitationRange[]) => {
          // 位标按区间保留（正文插角标用）；来源按 url 归并进来源列表（卡片展示用）。
          assistantMsg.citations = citations;
          const citeSources: SearchSource[] = [];
          let ci: number = 0;
          while (ci < citations.length) {
            const c: CitationRange = citations[ci];
            ci += 1;
            const src: SearchSource = { url: c.url, title: c.title };
            citeSources.push(src);
          }
          assistantMsg.sources = WebSearchService.mergeSources(assistantMsg.sources, citeSources);
          this.rebuildSessionReference();
        },
        onTitle: (title: string) => {
          // 用户已手动重命名过就不覆盖；否则用服务端标题替换本地兜底标题。
          if (!this.isAutoTitle(sess)) {
            return;
          }
          sess.title = title;
          this.rebuildSessionReference();
        },
        onToolCalls: (calls: ToolCallRequest[]) => {
          roundToolCalls = calls;
        },
        onServerToolCalls: (json: string) => {
          // 阅读链接：末块原样留存，下一轮随历史回传（signature 在里面）。
          assistantMsg.serverToolCallsJson = json;
        },
        onRefusal: (reason: string) => {
          // 官方要求：拒答时删除已展示的回答，改为拒答文案。
          assistantMsg.content = '';
          assistantMsg.reasoningContent = undefined;
          assistantMsg.status = 'error';
          assistantMsg.errorMessage = reason + '（可在「设置 > 工具」关闭内容安全后重试）';
          this.finishMarkdown(assistantMsg, true);
          this.rebuildSessionReference();
        },
        onIncomplete: (reason: string) => {
          // finish_reason=length：正文被截断（搜索/阅读链接后上下文用尽也会走到这里）。
          // 内容照常保留，只在气泡下方补一行提示；reason 仅用于日志。
          hilog.info(DOMAIN, TAG, 'incomplete: %{public}s', reason);
          assistantMsg.incomplete = true;
        },
        onComplete: () => {
          assistantMsg.status = 'success';
          this.isGenerating = false;
          this.finishMarkdown(assistantMsg, false);
          const rLen: number = assistantMsg.reasoningContent ? assistantMsg.reasoningContent.length : 0;
          hilog.info(DOMAIN, TAG, 'stream done: reasoning %{public}d chunks/%{public}d chars, content %{public}d chunks/%{public}d chars',
            this.reasonChunkCount, rLen, this.contentChunkCount, assistantMsg.content.length);
          if (assistantMsg.reasoningContent && assistantMsg.reasoningContent.length > 0) {
            if (!assistantMsg.thinkingDuration) {
              const dur: number = Math.max(1, Math.round(((thinkingEndTime > 0 ? thinkingEndTime : Date.now()) - thinkingStartTime) / 1000));
              assistantMsg.thinkingDuration = dur;
            }
            if (this.autoCollapseThinking) {
              if (!this.collapsedReasons.includes(assistantMsg.id)) {
                this.collapsedReasons.push(assistantMsg.id);
              }
            }
          }
          // 过程态只服务流式展示：落盘前清掉，避免历史里留下永不结束的「搜索中」。
          assistantMsg.searchState = undefined;
          assistantMsg.searchHint = undefined;
          // 标题只试一次：本轮开过 title 就记下，后续回复不再请求（失败时保留兜底标题）。
          if (titleEnabled) {
            sess.autoTitled = true;
          }
          // Reason: status 与折叠态都进入单条消息渲染键；同步数据源可刷新当前项而不重建整表。
          this.rebuildSessionReference();
          this.saveState();
          // 生图工具：模型决定调用后，后台跑百智云任务，结果追加到本条消息（不阻塞收尾）。
          // Business Rule: 一轮只执行第一个 generate_image 调用——模型偶尔会为同一句话
          //   连续下发两个调用，并发跑会互相覆盖 imageUrls（2026-11-20 实测「继续啊」触发两个）。
          if (roundToolCalls.length > 0) {
            let gi: number = 0;
            let imageStarted: boolean = false;
            while (gi < roundToolCalls.length) {
              if (!imageStarted && roundToolCalls[gi].name === 'generate_image') {
                imageStarted = true;
                this.runImageTool(assistantMsg, roundToolCalls[gi]);
              }
              gi += 1;
            }
          }
          finish();
        },
        onError: (errMsg: string) => {
          assistantMsg.status = 'error';
          assistantMsg.errorMessage = errMsg;
          this.isGenerating = false;
          this.finishMarkdown(assistantMsg, true);
          assistantMsg.searchState = undefined;
          assistantMsg.searchHint = undefined;
          this.rebuildSessionReference();
          this.saveState();
          finish();
        }
      };

      // 会话标题：每个会话只请求一次（session.autoTitled），且只在标题仍是自动生成时覆盖；
      // 服务端最多多等 5 秒，标题不计费。非 DeepSeek 服务商由 ChatService 内部拦掉。
      const titleEnabled: boolean = this.featureTitle && !sess.autoTitled && this.isAutoTitle(sess);

      this.abortStreaming = ChatService.streamChat({
        providerId: this.currentProviderId,
        apiKey: this.currentApiKey,
        model: this.currentModelId,
        temperature: speaker.temperature,
        messages: history,
        systemPrompt: this.systemPromptFor(speaker) + (webContext.length > 0 ? '\n\n' + webContext : ''),
        enableThinking: this.enableThinking,
        reasoningEffort: 'high',
        // 联网搜索：服务端工具只在 DeepSeek 生效；关闭时不声明 tools，行为与旧版完全一致。
        // 百智云模式在发送前已由客户端检索，不能再声明 DeepSeek 服务端工具（否则会搜两次）。
        enableWebSearch: this.enableWebSearch && this.webSearchProvider !== WEB_SEARCH_PROVIDER_BAIZHI &&
          WebSearchService.isSupported(this.currentProviderId),
        // 生图：客户端函数工具，与联网搜索同一套「声明式」触发——开关打开且服务商支持就声明，
        // 是否真的画由模型按用户意图自判（不再用本地关键词表猜意图，也不再要求先配 Key：
        // 缺 Key 时执行阶段会给出「未配置百智云生图 Key」的明确提示）。
        enableImageTool: this.featureImage && this.currentProviderId === 'deepseek',
        // 内容安全：官方基础风控（可关）。
        enableSafety: this.featureSafety,
        // 阅读链接：服务端抓用户消息里的 URL（是否读由模型判断）。
        enableReadUrl: this.featureReadUrl,
        // 用户元信息：日期/语言/所在地（latest_reminder 仅 DeepSeek 生效，ChatService 内收口）。
        reminder: {
          location: this.userLocation,
          language: I18nService.getLanguage()
        },
        // 文件解析开关：关闭后历史附件不再以 content 块回传。
        enableFiles: this.featureFiles,
        // 会话标题：服务端扩展字段（仅 DeepSeek），首轮才开启。
        enableTitle: titleEnabled
      }, callbacks);
    });
  }

  /**
   * 构建单聊系统提示词：只取角色自身的人设设定。
   * 用户身份卡功能已下线（2026-11-20），不再拼接「用户扮演谁」。
   */
  private systemPromptFor(speaker: CharacterCard): string {
    return speaker.systemPrompt.trim();
  }

  // ── 消息编辑 / 重新生成 / 分支切换 ──

  private openMsgActions(msgId: string): void {
    if (this.isGenerating) {
      return;
    }
    this.actionMsgId = msgId;
  }

  private closeMsgActions(): void {
    this.actionMsgId = '';
  }

  private actionMsg(): ChatMessage | undefined {
    const sess: ChatSession | undefined = this.getCurrentSession();
    if (!sess || this.actionMsgId.length === 0) {
      return undefined;
    }
    return this.findMessage(sess, this.actionMsgId);
  }

  /** 长按后点「编辑并重发」：打开编辑框并预填原文。 */
  private beginEdit(): void {
    const msg: ChatMessage | undefined = this.actionMsg();
    if (msg === undefined) {
      this.closeMsgActions();
      return;
    }
    this.editMsgId = msg.id;
    this.editMsgText = msg.content;
    this.actionMsgId = '';
    this.showEditDialog = true;
  }

  private cancelEdit(): void {
    this.showEditDialog = false;
    this.editMsgId = '';
    this.editMsgText = '';
  }

  /** 提交编辑：在原文同父下新建兄弟 user 节点（保留原分支），并生成新回复。 */
  private async confirmEdit(): Promise<void> {
    const sess: ChatSession | undefined = this.getCurrentSession();
    const newText: string = this.editMsgText.trim();
    if (!sess || this.editMsgId.length === 0 || newText.length === 0) {
      return;
    }
    if (!this.canSend()) {
      this.showEditDialog = false;
      return;
    }
    const original: ChatMessage | undefined = this.findMessage(sess, this.editMsgId);
    if (original === undefined) {
      this.cancelEdit();
      return;
    }
    const userMsg: ChatMessage = this.buildMessage('user', newText, original.parentId);
    // 编辑只改文字，附件沿原消息继承（否则重发后文档上下文会丢）。
    if (original.attachments !== undefined && original.attachments.length > 0) {
      userMsg.attachments = original.attachments;
    }
    let oi: number = 0;
    while (oi < original.mentionedIds.length) {
      userMsg.mentionedIds.push(original.mentionedIds[oi]);
      oi += 1;
    }
    this.attach(sess, userMsg);
    sess.updatedAt = Date.now();
    this.showEditDialog = false;
    this.editMsgId = '';
    this.editMsgText = '';
    this.rebuildSessionReference();
    this.scrollToBottom();
    /* [群聊下线已注释]
    if (sess.sceneMode === 'group' && sess.participantIds.length > 0) {
      await this.sendGroup(sess, userMsg);
      return;
    }
    */
    this.generateReply(sess, userMsg, this.getCurrentCharacter());
  }

  /**
   * 重新生成：同一 user 下新建助手兄弟分支。
   * Business Rule: 入口在回答下方的操作条（不再走长按菜单），因此直接接收消息对象；
   *   生成中或未配置 Key 时静默返回（按钮本身也会置灰）。
   */
  private async regenerateFrom(assistantMsg: ChatMessage): Promise<void> {
    if (this.isGenerating) {
      this.toast('正在生成，请稍候');
      return;
    }
    const sess: ChatSession | undefined = this.getCurrentSession();
    if (!sess || assistantMsg.role !== 'assistant') {
      return;
    }
    if (!this.canSend()) {
      return;
    }
    const userMsg: ChatMessage | undefined = this.findMessage(sess, assistantMsg.parentId);
    if (userMsg === undefined) {
      return;
    }
    // 换一条回答即换一段朗读内容：先停旧播放，避免旧音频盖住新一轮生成。
    this.stopReadAloud();
    let speaker: CharacterCard = this.getCurrentCharacter();
    const bySpeaker: CharacterCard | undefined = this.characterById(assistantMsg.speakerId);
    if (bySpeaker !== undefined) {
      speaker = bySpeaker;
    }
    this.generateReply(sess, userMsg, speaker);
  }

  private switchBranch(msg: ChatMessage, delta: number): void {
    if (this.isGenerating) {
      return;
    }
    const sess: ChatSession | undefined = this.getCurrentSession();
    if (!sess) {
      return;
    }
    const sibs: string[] = this.siblingsOf(sess, msg);
    if (sibs.length <= 1) {
      return;
    }
    let idx: number = this.siblingIndex(sess, msg);
    idx += delta;
    if (idx < 0 || idx >= sibs.length) {
      return;
    }
    const targetId: string = sibs[idx];
    if (msg.parentId.length === 0) {
      sess.activeRootId = targetId;
    } else {
      const parent: ChatMessage | undefined = this.findMessage(sess, msg.parentId);
      if (parent === undefined) {
        return;
      }
      parent.activeChildId = targetId;
    }
    sess.updatedAt = Date.now();
    this.rebuildSessionReference();
    this.saveState();
    this.scrollToBottom();
  }

  private stopGenerating(): void {
    if (this.isGenerating) {
      this.abortStreaming();
      this.isGenerating = false;
      const path: ChatMessage[] = this.activePath();
      if (path.length > 0) {
        const lastMsg: ChatMessage = path[path.length - 1];
        if (lastMsg.status === 'streaming') {
          lastMsg.status = 'success';
          const ctl: MarkdownController | undefined = this.mdControllers.get(lastMsg.id);
          if (ctl !== undefined) {
            try {
              ctl.typing.stop();
            } catch (_e) {
            }
          }
          this.finishMarkdown(lastMsg, true);
          // 中断时搜索可能仍在进行：清掉过程态，保留已拿到的来源（用户仍可回看）。
          lastMsg.searchState = undefined;
          lastMsg.searchHint = undefined;
        }
      }
      this.rebuildSessionReference();
      this.saveState();
      if (this.resolveCurrent !== undefined) {
        const done: () => void = this.resolveCurrent;
        this.resolveCurrent = undefined;
        done();
      }
    }
  }

  private branchCount(msg: ChatMessage): number {
    const sess: ChatSession | undefined = this.getCurrentSession();
    return sess ? this.siblingsOf(sess, msg).length : 1;
  }

  private branchIndex(msg: ChatMessage): number {
    const sess: ChatSession | undefined = this.getCurrentSession();
    return sess ? this.siblingIndex(sess, msg) : 0;
  }

  private isReasonCollapsed(id: string): boolean {
    return this.collapsedReasons.includes(id);
  }

  private isMsgThinkingStreaming(msg: ChatMessage): boolean {
    return msg.status === 'streaming' && (!msg.content || msg.content.length === 0);
  }

  private reasonDisplayTitle(msg: ChatMessage): string {
    if (this.isMsgThinkingStreaming(msg)) {
      return '正在思考...';
    }
    const sec: number = msg.thinkingDuration && msg.thinkingDuration > 0 ? msg.thinkingDuration : 1;
    return `已思考（用时 ${sec} 秒）`;
  }

  private toggleReason(id: string): void {
    try {
      this.getUIContext().animateTo({ duration: 250, curve: Curve.FastOutSlowIn }, () => {
        const idx: number = this.collapsedReasons.indexOf(id);
        if (idx >= 0) {
          this.collapsedReasons.splice(idx, 1);
        } else {
          this.collapsedReasons.push(id);
        }
        this.syncMessageSource();
      });
    } catch (_e) {
      const idx: number = this.collapsedReasons.indexOf(id);
      if (idx >= 0) {
        this.collapsedReasons.splice(idx, 1);
      } else {
        this.collapsedReasons.push(id);
      }
      this.syncMessageSource();
    }

    try {
      this.lastAnchorOffset = this.scroller.currentOffset().yOffset;
    } catch (_e) {
    }
  }

  private onThinkingAreaChange(msgId: string, oldH: number, newH: number): void {
    if (oldH === 0 && newH === 0) {
      return;
    }
    const delta: number = newH - oldH;
    if (Math.abs(delta) < 1) {
      return;
    }
    this.handleScrollAnchorOnHeightChange(msgId, delta);
  }

  private handleScrollAnchorOnHeightChange(msgId: string, delta: number): void {
    // Reason: 高度变化只做 offset 记账，避免让整表渲染键变化导致重建与滚动跳变，
    //   也不再每 token 重锚定（首 token 的一次性锚定已足够，重复 scrollToIndex 会与用户拖动互斥致页面拉不动）。
    //   参数保留签名供未来阈值策略使用（ArkTS 允许形参暂不读取）。

    // 浏览模式下平滑同步滚动锚点，防止视口异常跳变
    try {
      const currentOffset: number = this.scroller.currentOffset().yOffset;
      this.lastAnchorOffset = currentOffset;
    } catch (_e) {
    }
  }

  private initCollapsedReasons(): void {
    const cur: ChatSession | undefined = this.getCurrentSession();
    if (!cur) {
      return;
    }
    let i: number = 0;
    while (i < cur.messages.length) {
      const m: ChatMessage = cur.messages[i];
      if (m.reasoningContent && m.reasoningContent.length > 0) {
        if (!this.collapsedReasons.includes(m.id)) {
          this.collapsedReasons.push(m.id);
        }
      }
      i += 1;
    }
  }

  private copyText(text: string): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.toast('已复制');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'copy failed: %{public}s', String(err));
    }
  }

  /** 复制一条回答的正文（不含思考与来源卡片，与官方一致）。 */
  private copyMessage(msg: ChatMessage): void {
    if (msg.content.length > 0) {
      this.copyText(msg.content);
    }
  }

  private copyActionMsg(): void {
    const m: ChatMessage | undefined = this.actionMsg();
    this.closeMsgActions();
    if (m !== undefined && m.content.length > 0) {
      this.copyText(m.content);
    }
  }

  private getProviderName(id: string): string {
    const def: ProviderDefinition | undefined = findProvider(id);
    return def ? def.name : id;
  }

  private currentSessionTitle(): string {
    const session: ChatSession | undefined = this.getCurrentSession();
    return session !== undefined ? session.title : '新对话';
  }

  /**
   * 空态问候语：按本机时段切换（对齐官方版的「早上好 / 下午好 / 晚上好」）。
   * Business Rule: 首屏只留一句问候，不再附加标语、说明或英文小标题。
   */
  private greetingText(): string {
    const hour: number = new Date().getHours();
    let key: string = 'chat_greeting_morning';
    if (hour >= 23 || hour < 5) {
      key = 'chat_greeting_night';
    } else if (hour >= 18) {
      key = 'chat_greeting_evening';
    } else if (hour >= 12) {
      key = 'chat_greeting_afternoon';
    }
    return I18nService.t(key);
  }

  // ── UI 渲染 ──

  build() {
    Stack() {
      // 主对话内容
      Column() {
        // 顶部导航与状态栏
        Row() {
          // 左侧：三横杠，打开会话抽屉（内含设置入口）
          Column() {
            Row().width(16).height(2).backgroundColor(skinColor('text_primary'))
            Row().width(16).height(2).backgroundColor(skinColor('text_primary')).margin({ top: 3 })
            Row().width(16).height(2).backgroundColor(skinColor('text_primary')).margin({ top: 3 })
          }
          .width(34)
          .height(34)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(skinColor('chat_fill'))
          .borderRadius(17)
          .onClick(() => {
            this.openDrawer();
          })

          Column() {
            // 空态不显示会话标题与服务商副标题，首屏只留图标与问候语。
            if (this.activePath().length > 0) {
              Text(this.currentSessionTitle())
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(skinColor('text_title'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.getProviderName(this.currentProviderId))
                .fontSize(10)
                .fontColor(skinColor('text_muted'))
                .margin({ top: 2 })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 8, right: 8 })

          // 顶栏能力入口（对齐官方版式）：朗读最后一条回答 / 新建会话。
          Row() {
            Image($r('app.media.ic_speaker'))
              .width(19)
              .height(19)
          }
          .width(32)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(16)
          .backgroundColor(this.readingMsgId.length > 0 ? skinColor('chat_accent_soft') : '#00000000')
          .onClick(() => {
            this.readLastAnswer();
          })

          Row() {
            Image($r('app.media.ic_compose'))
              .width(19)
              .height(19)
          }
          .width(32)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(16)
          .margin({ left: 2 })
          .onClick(() => {
            this.startNewChat();
          })

          // 右侧：模型选择器入口
          Row() {
            Text(this.currentModelId.length > 0 ? this.currentModelId : '选择模型')
              .fontSize(12)
              .fontColor(skinColor('chat_accent'))
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .backgroundColor(skinColor('chat_accent_soft'))
          .border({ width: 1, color: skinColor('chat_accent_outline') })
          .borderRadius(16)
          .onClick(async () => {
            await this.loadConfiguredProviders();
            this.showModelPicker = true;
          })
        }
        .width('94%')
        .margin({ top: 12, bottom: 8 })

        // 提示条（仅有提示时展示）
        if (this.noticeText.length > 0) {
          Row() {
            Text(this.noticeText)
              .fontSize(11)
              .fontColor(skinColor('danger_text'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
          }
          .width('94%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(skinColor('danger_fill'))
          .borderRadius(14)
          .margin({ bottom: 6 })
        }

        Divider().color(skinColor('chat_border')).width('100%')

        // 空态：只有品牌标识 + 随时段变化的问候语（对齐官方首屏）。
        if (this.activePath().length === 0) {
          this.EmptyChatState()
        } else {
          // 对话气泡消息流（仅渲染当前激活分支；LazyForEach 只为视口内消息建 Markdown 实例）
          List({ scroller: this.scroller }) {
            LazyForEach(this.msgSource, (msg: ChatMessage) => {
              ListItem() {
                this.MessageBubble(msg)
              }
              .margin({ top: 10, bottom: 10 })
            }, (msg: ChatMessage) => this.msgRenderKey(msg))
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 20, right: 20 })
          .cachedCount(2)
          .scrollBar(BarState.Off)
          .onScrollIndex((start: number, end: number) => {
            this.handleScrollIndex(start, end);
          })
          .onScrollStop(() => {
            this.onChatScrollStop();
          })
          .onReachEnd(() => {
            // 用户回到底部附近：恢复底部跟随。
            this.userTookOver = false;
            this.showJumpBottom = false;
          })
        }

        // 底部输入区域
        Column() {
          // 已 @ 对象 chips（点移除）
          if (this.pendingMentions.length > 0) {
            Scroll() {
              Row() {
                ForEach(this.pendingMentions, (mid: string) => {
                  Row() {
                    Text(`@${this.characterName(mid)}`)
                      .fontSize(12)
                      .fontColor(skinColor('chat_accent'))
                    Text('  ×')
                      .fontSize(12)
                      .fontColor(skinColor('text_muted'))
                  }
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .backgroundColor(skinColor('chat_accent_soft'))
                  .borderRadius(12)
                  .margin({ right: 6 })
                  .onClick(() => {
                    this.removeMention(mid);
                  })
                }, (mid: string) => mid)
              }
              .padding({ left: 12, right: 12 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('96%')
            .margin({ bottom: 6 })
          }

          // 输入卡片（对齐官方 App）：整块圆角卡片，内含待发送文档、输入区、能力胶囊与发送/停止。
          Column() {
            // 待发送文档：解析中显示状态，就绪后可直接发送（点 × 移除）。
            if (this.pendingFiles.length > 0) {
              Scroll() {
                Row() {
                  ForEach(this.pendingFiles, (pf: PendingFile) => {
                    Row() {
                      if (pf.localUri.length > 0) {
                        Image(this.imageSrc(pf.localUri))
                          .width(26)
                          .height(26)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(6)
                          .margin({ right: 6 })
                      } else {
                        Image($r('app.media.ic_attach'))
                          .width(13)
                          .height(13)
                          .margin({ right: 4 })
                      }
                      Text(pf.status === 'uploading' ? `${pf.fileName} 解析中…` : pf.fileName)
                        .fontSize(12)
                        .fontColor(skinColor('text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .constraintSize({ maxWidth: 170 })
                      Text('×')
                        .fontSize(14)
                        .fontColor(skinColor('text_muted'))
                        .margin({ left: 6 })
                        .onClick(() => {
                          this.removePendingFile(pf);
                        })
                    }
                    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                    .backgroundColor(skinColor('chat_fill'))
                    .borderRadius(10)
                    .margin({ right: 6, bottom: 4 })
                  }, (pf: PendingFile) => `${pf.fileName}_${pf.status}`)
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
            }

            // 识别状态提示（录音状态由「按住说话」区自己展示）。
            if (this.transcribing) {
              Row() {
                LoadingProgress()
                  .width(13)
                  .height(13)
                  .color(skinColor('chat_accent'))
                Text('  正在识别语音…')
                  .fontSize(12)
                  .fontColor(skinColor('text_secondary'))
              }
              .width('100%')
              .margin({ bottom: 4 })
            }

            if (this.voiceMode) {
              // 语音模式：整块输入区变成「按住说话」，按下录音、松开转写。
              Row() {
                Text(this.recording ? `松开结束 ${this.recordTimeText()}` : '按住说话')
                  .fontSize(16)
                  .fontWeight(this.recording ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.recording ? skinColor('danger_text') : skinColor('text_primary'))
              }
              .width('100%')
              .height(INPUT_BASE_HEIGHT)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .backgroundColor(this.recording ? skinColor('chat_accent_soft') : '#00000000')
              .borderRadius(16)
              .onTouch((event: TouchEvent) => {
                this.onHoldTouch(event);
              })
            } else {
              Stack({ alignContent: Alignment.TopEnd }) {
                TextArea({ placeholder: '发消息或按住说话', text: this.inputText })
                  .width('100%')
                  .height(this.inputExpanded ? INPUT_EXPANDED_HEIGHT : INPUT_BASE_HEIGHT)
                  .backgroundColor('#00000000')
                  .border({ width: 0 })
                  .fontSize(16)
                  .placeholderColor(skinColor('text_faint'))
                  .padding({ left: 4, right: this.showExpandToggle() ? 32 : 4, top: 2, bottom: 2 })
                  .onChange((val: string) => {
                    this.inputText = val;
                  })
                  .onFocus(() => {
                    this.onInputFocus();
                  })

                // 展开/收起只在「内容超过一行」或已展开时出现；平时让输入框自己内部滚动。
                if (this.showExpandToggle()) {
                  Image(this.inputExpanded ? $r('app.media.ic_collapse') : $r('app.media.ic_expand'))
                    .width(14)
                    .height(14)
                    .margin({ right: 6, top: 6 })
                    .onClick(() => {
                      this.inputExpanded = !this.inputExpanded;
                    })
                }
              }
              .width('100%')
            }

            Row() {
              ThinkingButton({
                isEnabled: this.enableThinking,
                providerId: this.currentProviderId,
                modelId: this.currentModelId,
                onToggle: (val: boolean) => {
                  this.enableThinking = val;
                }
              })
              WebSearchButton({
                isEnabled: this.enableWebSearch,
                providerId: this.currentProviderId,
                onToggle: (val: boolean) => {
                  this.setWebSearch(val);
                }
              })
              Blank()
              // 附件（DeepSeek Files API）：选文件 → 解析 → 随消息以 file_id 引用。
              Row() {
                Image($r('app.media.ic_plus'))
                  .width(18)
                  .height(18)
              }
              .width(34)
              .height(34)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .borderRadius(17)
              .border({ width: 1.6, color: skinColor('chat_border') })
              .margin({ right: 8 })
              .opacity(this.currentProviderId === 'deepseek' ? 1 : 0.4)
              .onClick(() => {
                this.showAttachSheet = true;
              })

              if (this.transcribing) {
                Column() {
                  LoadingProgress()
                    .width(22)
                    .height(22)
                    .color(skinColor('chat_accent'))
                }
                .width(40)
                .height(40)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
              } else if (this.voiceMode) {
                // 语音模式：键盘钮切回文字输入（录音中切换会丢弃本次录音）。
                Column() {
                  Image($r('app.media.ic_keyboard'))
                    .width(20)
                    .height(20)
                }
                .width(40)
                .height(40)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .borderRadius(20)
                .border({ width: 1.6, color: skinColor('chat_border') })
                .onClick(() => {
                  this.exitVoiceMode();
                })
              } else if (this.isGenerating) {
                Column() {
                  Text('■')
                    .fontSize(12)
                    .fontColor('#FFFFFF')
                }
                .width(40)
                .height(40)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .borderRadius(20)
                .backgroundColor(skinColor('danger_text'))
                .onClick(() => {
                  this.stopGenerating();
                })
              } else if (this.hasSendableInput()) {
                Column() {
                  Text('↑')
                    .fontSize(19)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(skinColor('chat_accent_contrast'))
                }
                .width(40)
                .height(40)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .borderRadius(20)
                .backgroundColor(skinColor('chat_accent_solid'))
                .onClick(() => {
                  this.sendMessage();
                })
              } else if (this.featureAsr) {
                // 输入框为空：麦克风切换到「按住说话」模式。
                Column() {
                  Image($r('app.media.ic_mic'))
                    .width(20)
                    .height(20)
                }
                .width(40)
                .height(40)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .borderRadius(20)
                .border({ width: 1.6, color: skinColor('chat_border') })
                .onClick(() => {
                  this.enterVoiceMode();
                })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ top: 2 })
          }
          .width('96%')
          .padding({ left: 12, right: 8, top: 10, bottom: 8 })
          .backgroundColor(skinColor('chat_surface'))
          .borderRadius(22)
          .border({ width: 1, color: skinColor('chat_border') })
          .shadow({ radius: 10, color: 'rgba(0,0,0,0.05)', offsetX: 0, offsetY: 3 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 12, bottom: 14 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(skinColor('chat_surface'))
      // 右滑打开历史抽屉：只识别向右的平移，纵向滚动（消息列表）与左滑不受影响。
      .gesture(
        PanGesture({ direction: PanDirection.Right, distance: 10 })
          .onActionUpdate((event: GestureEvent) => {
            this.drawerSwipeOffset = event.offsetX;
          })
          .onActionEnd(() => {
            this.settleDrawerSwipe();
          })
          .onActionCancel(() => {
            this.drawerSwipeOffset = 0;
          })
      )

      // ── 图片预览浮层（Markdown 图片点击，全屏深底 + 点空白/按钮关闭） ──
      if (this.previewImage.length > 0) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.previewImage = '';
            })
          Image(this.imageSrc(this.previewImage))
            .width('92%')
            .objectFit(ImageFit.Contain)
            .constraintSize({ maxHeight: '70%' })
            .borderRadius(12)
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.previewImage = '';
            })
          Button('关闭')
            .margin({ bottom: 28 })
            .onClick(() => {
              this.previewImage = '';
            })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
      }

      // ── 0. 回到底部浮动按钮（官方同款圆形，视口离开底部时浮现） ──
      if (this.showJumpBottom) {
        Column() {
          Image($r('app.media.ic_scroll_down'))
            .width(18)
            .height(18)
        }
        .width(42)
        .height(42)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(21)
        .backgroundColor(skinColor('chat_surface'))
        .border({ width: 1, color: skinColor('chat_border') })
        .shadow({ radius: 14, color: 'rgba(35,30,20,0.16)', offsetX: 0, offsetY: 4 })
        .position({ right: 16, bottom: 132 })
        .transition(TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: 16 })).animation({ duration: 200, curve: Curve.FastOutSlowIn }))
        .onClick(() => {
          this.jumpToBottom();
        })
      }

      // ── 1. 侧边历史会话抽屉（铺满整屏：状态栏/导航栏区域不留白条，与官方一致） ──
      if (this.showDrawer) {
        // 蒙层单独一层：只有背景层用 expandSafeArea，内容层才不会压到状态栏下。
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(skinColor('overlay_scrim'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          .transition(TransitionEffect.opacity(0).animation({ duration: 280, curve: Curve.EaseOut }))
          .onClick(() => {
            this.showDrawer = false;
          })

        Row() {
          Stack({ alignContent: Alignment.TopStart }) {
            // 面板底色层：铺满整屏高度（含系统栏），底下的内容层仍留在安全区内。
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor(skinColor('sidebar_surface'))
              .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

            Column() {
              // 抽屉头部：搜索会话 + 新会话（对齐官方：顶部是搜索框，不再是标题行）
              Row() {
                Row() {
                  Image($r('app.media.ic_search'))
                    .width(15)
                    .height(15)
                    .margin({ left: 12, right: 6 })
                  TextInput({ placeholder: '搜索会话内容' })
                    .layoutWeight(1)
                    .height(36)
                    .padding({ left: 0, right: 8 })
                    .backgroundColor(Color.Transparent)
                    .placeholderColor(skinColor('text_muted'))
                    .placeholderFont({ size: 13 })
                    .fontSize(13)
                    .onChange((value: string) => {
                      this.sessionQuery = value;
                    })
                }
                .layoutWeight(1)
                .height(38)
                .backgroundColor(skinColor('chat_surface'))
                .borderRadius(19)

                Button('+ 新会话')
                  .fontSize(12)
                  .height(36)
                  .margin({ left: 8 })
                  .backgroundColor(skinColor('chat_accent_solid'))
                  .fontColor(skinColor('chat_accent_contrast'))
                  .borderRadius(18)
                  .onClick(async () => {
                    await this.createNewSession();
                    this.showDrawer = false;
                    this.pendingParticipants = [];
                    this.characterSheetMode = 'select';
                    this.showCharacterSheet = true;
                  })
              }
              .width('90%')
              .margin({ top: 14, bottom: 10 })

              // 会话列表（过滤后为空时给明确空态，避免只剩一条分割线）
              if (this.filteredSessions().length === 0) {
                Column() {
                  Text(this.sessionQuery.trim().length > 0 ? '没有匹配的会话' : '还没有历史会话')
                    .fontSize(13)
                    .fontColor(skinColor('text_muted'))
                }
                .width('100%')
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
              } else {
                List() {
                  ForEach(this.filteredSessions(), (sess: ChatSession) => {
                    ListItem() {
                      Row() {
                        Column() {
                          Row() {
                            if (sess.isPrivate) {
                              Image($r('app.media.ic_lock'))
                                .width(13)
                                .height(13)
                                .margin({ right: 4 })
                            }
                            Text(sess.title)
                              .fontSize(15)
                              .fontWeight(sess.id === this.currentSessionId ? FontWeight.Bold : FontWeight.Normal)
                              .fontColor(sess.id === this.currentSessionId ? skinColor('chat_accent') : skinColor('text_primary'))
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                              .layoutWeight(1)
                          }
                          .width('100%')
                          Text(`${this.getProviderName(sess.providerId)} · ${sess.messages.length} 条消息`)
                            .fontSize(11)
                            .fontColor(skinColor('text_muted'))
                            .margin({ top: 4 })
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)

                        Text('›')
                          .fontSize(20)
                          .fontColor(skinColor('icon_muted'))
                      }
                      .width('100%')
                      .padding({ left: 18, right: 18, top: 12, bottom: 12 })
                      // Reason: 官方侧栏是「整屏浅灰 + 扁平行」，选中项用白底浮起，不再给每行描边卡片。
                      .backgroundColor(sess.id === this.currentSessionId ? skinColor('chat_surface') : Color.Transparent)
                      .borderRadius(14)
                      .onClick(() => {
                        this.openSessionWithPrivacy(sess);
                      })
                      .gesture(LongPressGesture({ repeat: false }).onAction(() => {
                        this.openSessActions(sess.id);
                      }))
                    }
                    .margin({ bottom: 2 })
                  }, (sess: ChatSession) => `${sess.id}_${sess.title}_${sess.updatedAt}_${sess.isPrivate ? 1 : 0}`)
                }
                .width('100%')
                .layoutWeight(1)
                .margin({ top: 6 })
                .scrollBar(BarState.Off)
              }

              // 底部：角色管理 + 设置入口
              Divider().color(skinColor('chat_border')).width('100%')
              Row() {
                Column() {
                  Image($r('app.media.ic_character'))
                    .width(18)
                    .height(18)
                }
                .width(34)
                .height(34)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(skinColor('chat_surface'))
                .borderRadius(17)
                Text('角色管理')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .margin({ left: 8 })
                Blank()
                Text('›')
                  .fontSize(20)
                  .fontColor(skinColor('icon_muted'))
              }
              .width('90%')
              .padding({ top: 12, bottom: 8 })
              .onClick(() => {
                this.showDrawer = false;
                this.characterSheetMode = 'manage';
                this.pendingParticipants = [];
                this.showCharacterSheet = true;
              })
              Row() {
                Column() {
                  Image($r('app.media.ic_settings'))
                    .width(18)
                    .height(18)
                }
                .width(34)
                .height(34)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(skinColor('chat_surface'))
                .borderRadius(17)
                Text('设置')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .margin({ left: 8 })
                Blank()
                Text('›')
                  .fontSize(20)
                  .fontColor(skinColor('icon_muted'))
              }
              .width('90%')
              .padding({ top: 8, bottom: 18 })
              .onClick(() => {
                this.showDrawer = false;
                this.openSettings();
              })
            }
            .width('100%')
            .height('100%')
          }
          .width('80%')
          .height('100%')
          .transition(TransitionEffect.translate({ x: -320 }).animation({ duration: 320, curve: Curve.ExtremeDeceleration }))

          // 空白处点击收回
          Blank()
            .layoutWeight(1)
            .height('100%')
            .onClick(() => {
              this.showDrawer = false;
            })
        }
        .width('100%')
        .height('100%')
      }

      // ── 1.5 附件来源面板（拍照 / 相册 / 文件） ──
      if (this.showAttachSheet) {
        this.AttachSheet()
      }

      // ── 2. 模型与供应商选择弹窗 ──
      if (this.showModelPicker) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.showModelPicker = false;
            })

          Column() {
            Row() {
              Text('选择服务商与模型')
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
              Blank()
              if (this.fetchingModels) {
                Text('拉取中...')
                  .fontSize(12)
                  .fontColor(skinColor('chat_accent'))
              } else {
                Text('刷新列表')
                  .fontSize(12)
                  .fontColor(skinColor('chat_accent'))
                  .onClick(async () => {
                    await this.loadConfiguredProviders();
                    await this.refreshModelList();
                  })
              }
            }
            .width('92%')
            .margin({ top: 18, bottom: 12 })

            // 厂商横向选择器（仅展示已配置 API Key 的服务商，禁用滚动条）
            if (this.configuredProviders.length === 0) {
              Text('尚未配置服务商 API Key，请到「设置 > 资产监控」添加')
                .fontSize(13)
                .fontColor(skinColor('text_muted'))
                .width('92%')
                .margin({ bottom: 12 })
            } else {
              Scroll() {
                Row() {
                  ForEach(this.configuredProviders, (p: ProviderDefinition) => {
                    Button(p.name)
                      .fontSize(12)
                      .height(32)
                      .backgroundColor(p.id === this.currentProviderId ? skinColor('chat_accent_solid') : skinColor('chat_fill'))
                      .fontColor(p.id === this.currentProviderId ? skinColor('chat_accent_contrast') : skinColor('text_primary'))
                      .borderRadius(16)
                      .margin({ right: 8 })
                      .onClick(async () => {
                        this.currentProviderId = p.id;
                        const cur: ChatSession | undefined = this.getCurrentSession();
                        if (cur) {
                          cur.providerId = p.id;
                        }
                        await this.reloadApiKey();
                        await this.refreshModelList();
                        if (isThinkingSupported(this.currentProviderId, this.currentModelId)) {
                          this.enableThinking = true;
                        }
                      })
                  }, (p: ProviderDefinition) => p.id)
                }
                .padding({ left: 16, right: 16 })
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
              .margin({ bottom: 12 })
            }

            Divider().color(skinColor('divider')).width('92%')

            // 实时可用模型列表
            if (this.availableModels.length === 0 && !this.fetchingModels) {
              Column() {
                Text('未探测到可用模型')
                  .fontSize(14)
                  .fontColor(skinColor('text_muted'))
                  .margin({ top: 40, bottom: 6 })
                Text('请确认已在「设置 > 资产监控」配置对应厂商的正确 API Key')
                  .fontSize(12)
                  .fontColor(skinColor('text_faint'))
              }
              .width('100%')
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
            } else {
              List() {
                ForEach(this.availableModels, (m: ModelInfo) => {
                  ListItem() {
                    Row() {
                      Text(m.id)
                        .fontSize(14)
                        .fontColor(m.id === this.currentModelId ? skinColor('chat_accent') : skinColor('text_primary'))
                        .fontWeight(m.id === this.currentModelId ? FontWeight.Bold : FontWeight.Normal)
                        .layoutWeight(1)

                      if (isThinkingSupported(this.currentProviderId, m.id)) {
                        Text('深度思考')
                          .fontSize(10)
                          .fontColor(skinColor('chat_accent'))
                          .backgroundColor(skinColor('chat_accent_soft'))
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .borderRadius(8)
                          .margin({ right: 8 })
                      }

                      if (m.id === this.currentModelId) {
                        Text('已选')
                          .fontSize(12)
                          .fontColor(skinColor('chat_accent'))
                      }
                    }
                    .width('100%')
                    .padding({ top: 14, bottom: 14, left: 16, right: 16 })
                    .borderRadius(16)
                    .backgroundColor(m.id === this.currentModelId ? skinColor('chat_accent_soft_selected') : skinColor('chat_surface'))
                    .border({ width: m.id === this.currentModelId ? 1 : 0, color: skinColor('chat_accent_outline') })
                    .onClick(() => {
                      this.currentModelId = m.id;
                      const cur: ChatSession | undefined = this.getCurrentSession();
                      if (cur) {
                        cur.modelId = m.id;
                      }
                      if (isThinkingSupported(this.currentProviderId, m.id)) {
                        this.enableThinking = true;
                      }
                      this.saveState();
                      this.showModelPicker = false;
                    })
                  }
                }, (m: ModelInfo) => m.id)
              }
              .width('92%')
              .layoutWeight(1)
              .margin({ top: 8, bottom: 12 })
              .scrollBar(BarState.Off)
            }

            Button('关闭')
              .width('92%')
              .height(46)
              .backgroundColor(skinColor('chat_fill'))
              .fontColor(skinColor('text_primary'))
              .borderRadius(16)
              .margin({ bottom: 20 })
              .onClick(() => {
                this.showModelPicker = false;
              })
          }
          .width('100%')
          .height('65%')
          .backgroundColor(skinColor('chat_surface'))
          .borderRadius({ topLeft: 28, topRight: 28 })
          .border({ width: 1, color: skinColor('chat_border') })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
      }

      // ── 3. 角色卡配置抽屉 ──
      if (this.showCharacterSheet) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.showCharacterSheet = false;
            })

          Column() {
            // 顶部拖动条（视觉提示下拉关闭）
            Row()
              .width(36)
              .height(4)
              .backgroundColor(skinColor('chat_border'))
              .borderRadius(2)
              .margin({ top: 10, bottom: 14 })

            Row() {
              Column() {
                Text(this.characterSheetMode === 'manage' ? '角色管理' : '选择角色')
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(skinColor('text_title'))
                Text(this.characterSheetMode === 'manage' ? '管理你的角色卡' : '选择一个角色开始对话')
                  .fontSize(12)
                  .fontColor(skinColor('text_muted'))
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (this.characterSheetMode === 'manage') {
                Button('+ 新建角色')
                  .fontSize(12)
                  .height(34)
                  .borderRadius(17)
                  .backgroundColor(skinColor('chat_accent_soft'))
                  .fontColor(skinColor('chat_accent'))
                  .border({ width: 1, color: skinColor('chat_accent_outline') })
                  .margin({ right: 10 })
                  .onClick(() => {
                    this.openCharEdit();
                  })
              }
              Text('✕')
                .fontSize(15)
                .fontColor(skinColor('text_secondary'))
                .width(30)
                .height(30)
                .textAlign(TextAlign.Center)
                .backgroundColor(skinColor('chat_fill'))
                .borderRadius(15)
                .onClick(() => {
                  this.showCharacterSheet = false;
                })
            }
            .width('92%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 14 })

            if (this.characters.length === 0) {
              Column() {
                Text('暂无角色卡')
                  .fontSize(14)
                  .fontColor(skinColor('text_muted'))
                  .margin({ top: 30, bottom: 6 })
                Text(this.characterSheetMode === 'manage' ? '点击右上角“新建角色”创建你的第一个角色' : '请先到历史抽屉“角色管理”中新建角色卡')
                  .fontSize(12)
                  .fontColor(skinColor('text_faint'))
              }
              .width('100%')
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
            } else {
            List() {
              ForEach(this.characters, (char: CharacterCard) => {
                  ListItem() {
                    Row() {
                      Text(char.name.length > 0 ? char.name.substring(0, 1) : '·')
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(skinColor('chat_accent'))
                        .width(38)
                        .height(38)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(skinColor('chat_fill'))
                        .border({ width: 1, color: skinColor('chat_accent_outline') })
                        .borderRadius(19)
                        .margin({ right: 12 })
                      Column() {
                        Text(char.name)
                        .fontSize(15)
                        .fontWeight(this.isPendingParticipant(char.id) ? FontWeight.Bold : FontWeight.Medium)
                        .fontColor(this.isPendingParticipant(char.id) ? skinColor('chat_accent') : skinColor('text_primary'))
                      if (char.description.trim().length > 0) {
                        Text(char.description)
                          .fontSize(12)
                          .fontColor(skinColor('text_secondary'))
                          .margin({ top: 4 })
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    if (this.characterSheetMode === 'manage') {
                      Text('›')
                        .fontSize(20)
                        .fontColor(skinColor('icon_muted'))
                        .margin({ left: 8 })
                    } else if (this.isPendingParticipant(char.id)) {
                      Text('✓')
                        .fontSize(13)
                        .fontColor(skinColor('chat_accent_contrast'))
                        .width(22)
                        .height(22)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(skinColor('chat_accent_solid'))
                        .borderRadius(11)
                        .margin({ left: 8 })
                    } else {
                      Row()
                        .width(22)
                        .height(22)
                        .borderRadius(11)
                        .border({ width: 1.5, color: skinColor('chat_border') })
                        .margin({ left: 8 })
                    }
                  }
                  .width('100%')
                  .padding(14)
                  .borderRadius(12)
                  .backgroundColor(this.isPendingParticipant(char.id) ? skinColor('chat_accent_soft_selected') : skinColor('chat_surface_alt'))
                  .border({
                    width: this.characterSheetMode === 'select' && this.isPendingParticipant(char.id) ? 1.5 : 0,
                    color: skinColor('chat_accent_outline')
                  })
                  .onClick(() => {
                    if (this.characterSheetMode === 'manage') {
                      this.openCharEdit(char);
                    } else {
                      this.togglePendingParticipant(char.id);
                    }
                  })
                  .gesture(LongPressGesture({ repeat: false }).onAction(() => {
                    this.openCharActions(char.id);
                  }))
                }
                .margin({ bottom: 8 })
              }, (char: CharacterCard) => `${char.id}_${char.name}`)
            }
            .width('92%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            }

            if (this.characterSheetMode === 'select') {
              Button('开始对话')
                .width('92%')
                .height(46)
                .fontSize(15)
                .borderRadius(23)
                .backgroundColor(this.pendingParticipants.length > 0 ? skinColor('chat_accent_solid') : skinColor('chat_fill'))
                .fontColor(this.pendingParticipants.length > 0 ? skinColor('chat_accent_contrast') : skinColor('text_muted'))
                .margin({ top: 12, bottom: 22 })
                .enabled(this.pendingParticipants.length > 0)
                .onClick(() => {
                  this.confirmParticipants();
                })
            } else {
              Blank().height(22)
            }
          }
          .width('100%')
          .height('70%')
          .backgroundColor(skinColor('chat_surface'))
          .borderRadius({ topLeft: 28, topRight: 28 })
          .border({ width: 1, color: skinColor('chat_border') })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
      }

      // ── 4. 角色卡新建/编辑弹窗 ──
      if (this.showCharEditDialog) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.showCharEditDialog = false;
            })

          Column() {
            Text(this.editingCharId.length > 0 ? '编辑角色卡' : '新建角色卡')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 18, bottom: 12 })

            Scroll() {
              Column() {
                Text('角色名称')
                  .fontSize(12)
                  .fontColor(skinColor('text_secondary'))
                  .width('92%')
                  .margin({ bottom: 4 })
                TextInput({ placeholder: '', text: this.editingCharName })
                  .width('92%')
                  .height(46)
                  .backgroundColor(skinColor('chat_surface'))
                  .borderRadius(14)
                  .border({ width: 1, color: skinColor('chat_border') })
                  .margin({ bottom: 12 })
                  .onChange((v: string) => {
                    this.editingCharName = v;
                  })

                Text('系统设定')
                  .fontSize(12)
                  .fontColor(skinColor('text_secondary'))
                  .width('92%')
                  .margin({ bottom: 4 })
                TextArea({ placeholder: '设定角色的语气、行为模式、知识范畴...', text: this.editingCharPrompt })
                  .width('92%')
                  .height(110)
                  .backgroundColor(skinColor('chat_surface'))
                  .borderRadius(16)
                  .border({ width: 1, color: skinColor('chat_border') })
                  .margin({ bottom: 12 })
                  .onChange((v: string) => {
                    this.editingCharPrompt = v;
                  })

                Text('初次问候语')
                  .fontSize(12)
                  .fontColor(skinColor('text_secondary'))
                  .width('92%')
                  .margin({ bottom: 4 })
                TextInput({ placeholder: '第一句主动打招呼的消息', text: this.editingCharFirstMsg })
                  .width('92%')
                  .height(46)
                  .backgroundColor(skinColor('chat_surface'))
                  .borderRadius(14)
                  .border({ width: 1, color: skinColor('chat_border') })
                  .margin({ bottom: 16 })
                  .onChange((v: string) => {
                    this.editingCharFirstMsg = v;
                  })
              }
              .width('100%')
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)

            Row() {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(skinColor('chat_fill'))
                .fontColor(skinColor('text_primary'))
                .margin({ right: 8 })
                .onClick(() => {
                  this.showCharEditDialog = false;
                })
              Button('保存')
                .layoutWeight(1)
                .backgroundColor(skinColor('chat_accent_solid'))
                .fontColor(skinColor('chat_accent_contrast'))
                .onClick(() => {
                  this.saveCharacterEdit();
                })
            }
            .width('92%')
            .margin({ bottom: 20 })
          }
          .width('100%')
          .height('80%')
          .backgroundColor(skinColor('chat_surface'))
          .borderRadius({ topLeft: 28, topRight: 28 })
          .border({ width: 1, color: skinColor('chat_border') })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
      }

      // ── 5. 消息长按操作菜单 ──
      if (this.actionMsgId !== '') {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.closeMsgActions();
            })
          Column() {
            Text('消息操作')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 18, bottom: 10 })
            // 长按菜单只服务用户消息（编辑并重发）；助手消息的操作已移到回答下方的操作条。
            this.MsgActionRow('编辑并重发', () => {
              this.beginEdit();
            })
            this.MsgActionRow('复制', () => {
              this.copyActionMsg();
            })
            Button('取消')
              .width('92%')
              .height(44)
              .backgroundColor(skinColor('chat_fill'))
              .fontColor(skinColor('text_primary'))
              .borderRadius(14)
              .margin({ top: 8, bottom: 16 })
              .onClick(() => {
                this.closeMsgActions();
              })
          }
          .width('100%')
          .backgroundColor(skinColor('chat_surface'))
          .borderRadius({ topLeft: 28, topRight: 28 })
          .border({ width: 1, color: skinColor('chat_border') })
          .transition(TransitionEffect.translate({ y: 360 }).animation({ duration: 320, curve: Curve.ExtremeDeceleration }))
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
        .transition(TransitionEffect.opacity(0).animation({ duration: 280, curve: Curve.EaseOut }))
      }

      // ── 5.5 @ 成员选择小弹窗（轻量快速选择） ──
      if (this.showMentionPicker) {
        Column() {
          Blank()
            .onClick(() => {
              this.showMentionPicker = false;
            })
          Column() {
            Text('@ 谁来回答')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 14, bottom: 8 })
            List() {
              ForEach(this.participantCards(), (pc: CharacterCard) => {
                ListItem() {
                  Row() {
                    Text(pc.name)
                      .fontSize(14)
                      .fontWeight(this.pendingMentions.includes(pc.id) ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(this.pendingMentions.includes(pc.id) ? skinColor('chat_accent') : skinColor('text_primary'))
                      .layoutWeight(1)
                    if (this.pendingMentions.includes(pc.id)) {
                      Text('✓')
                        .fontSize(16)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(skinColor('chat_accent'))
                    }
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                  .borderRadius(8)
                  .backgroundColor(this.pendingMentions.includes(pc.id) ? skinColor('chat_accent_soft_selected') : skinColor('chat_surface'))
                  .onClick(() => {
                    this.toggleMention(pc.id);
                  })
                }
              }, (pc: CharacterCard) => pc.id)
            }
            .width('90%')
            .scrollBar(BarState.Off)
            .constraintSize({ maxHeight: 260 })
            Button('完成')
              .width('90%')
              .height(44)
              .backgroundColor(skinColor('chat_accent_solid'))
              .fontColor(skinColor('chat_accent_contrast'))
              .borderRadius(14)
              .margin({ top: 8, bottom: 14 })
              .onClick(() => {
                this.showMentionPicker = false;
              })
          }
          .width('76%')
          .backgroundColor(skinColor('chat_surface'))
          .borderRadius(16)
          Blank()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
      }

      // ── 6. 编辑并重发弹窗 ──
      if (this.showEditDialog) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.cancelEdit();
            })
          Column() {
            Text('编辑并重发')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 18, bottom: 4 })
            Text('修改后将作为新分支发送，原对话会保留')
              .fontSize(12)
              .fontColor(skinColor('text_muted'))
              .margin({ bottom: 12 })
            TextArea({ placeholder: '修改消息内容...', text: this.editMsgText })
              .width('92%')
              .height(120)
              .backgroundColor(skinColor('chat_surface'))
              .borderRadius(16)
              .border({ width: 1, color: skinColor('chat_border') })
              .margin({ bottom: 16 })
              .onChange((v: string) => {
                this.editMsgText = v;
              })
            Row() {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(skinColor('chat_fill'))
                .fontColor(skinColor('text_primary'))
                .margin({ right: 8 })
                .onClick(() => {
                  this.cancelEdit();
                })
              Button('发送')
                .layoutWeight(1)
                .backgroundColor(skinColor('chat_accent_solid'))
                .fontColor(skinColor('chat_accent_contrast'))
                .enabled(this.editMsgText.trim().length > 0)
                .onClick(() => {
                  this.confirmEdit();
                })
            }
            .width('92%')
            .margin({ bottom: 20 })
          }
          .width('100%')
          .backgroundColor(skinColor('chat_surface'))
          .borderRadius({ topLeft: 28, topRight: 28 })
          .border({ width: 1, color: skinColor('chat_border') })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
      }

      // ── 8. 历史会话长按操作菜单 ──
      if (this.sessActionId !== '' && !this.showRenameDialog && !this.showDeleteConfirm) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.closeSessActions();
            })
          Column() {
            Text(this.sessActionTitle())
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 18, bottom: 10 })
            this.MsgActionRow(this.sessActionIsPrivate() ? '取消保密' : '保密', () => {
              this.toggleSessPrivacy();
            })
            this.MsgActionRow('重命名', () => {
              this.beginRename();
            })
            this.MsgActionRow('删除', () => {
              this.askDeleteSession();
            })
            Button('取消')
              .width('92%')
              .height(44)
              .backgroundColor(skinColor('chat_fill'))
              .fontColor(skinColor('text_primary'))
              .borderRadius(14)
              .margin({ top: 8, bottom: 16 })
              .onClick(() => {
                this.closeSessActions();
              })
          }
          .width('100%')
          .backgroundColor(skinColor('chat_surface'))
          .borderRadius({ topLeft: 28, topRight: 28 })
          .border({ width: 1, color: skinColor('chat_border') })
          .transition(TransitionEffect.translate({ y: 360 }).animation({ duration: 320, curve: Curve.ExtremeDeceleration }))
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
        .transition(TransitionEffect.opacity(0).animation({ duration: 280, curve: Curve.EaseOut }))
      }

      // ── 9. 会话重命名弹窗 ──
      if (this.showRenameDialog) {
        Column() {
          Blank()
          Column() {
            Text('重命名会话')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 20, bottom: 12 })
            TextInput({ placeholder: '输入新名称', text: this.renameText })
              .width('90%')
              .height(46)
              .backgroundColor(skinColor('chat_surface'))
              .borderRadius(14)
              .border({ width: 1, color: skinColor('chat_border') })
              .margin({ bottom: 16 })
              .onChange((v: string) => {
                this.renameText = v;
              })
            Row() {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(skinColor('chat_fill'))
                .fontColor(skinColor('text_primary'))
                .margin({ right: 8 })
                .onClick(() => {
                  this.cancelRename();
                })
              Button('保存')
                .layoutWeight(1)
                .backgroundColor(skinColor('chat_accent_solid'))
                .fontColor(skinColor('chat_accent_contrast'))
                .enabled(this.renameText.trim().length > 0)
                .onClick(() => {
                  this.confirmRename();
                })
            }
            .width('90%')
            .margin({ bottom: 20 })
          }
          .width('88%')
          .backgroundColor(skinColor('chat_surface'))
          .borderRadius(16)
          Blank()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
      }

      // ── 10. 会话删除二次确认（复用组件） ──
      ConfirmDialog({
        show: this.showDeleteConfirm,
        title: '确认删除该会话？',
        message: this.sessActionTitle(),
        confirmText: '删除',
        danger: true,
        onConfirm: () => {
          this.confirmDeleteSession();
        },
        onCancel: () => {
          this.cancelDeleteSession();
        }
      })

      // ── 7. 角色卡长按操作菜单 ──
      if (this.charActionId !== '' && !this.showCharDeleteConfirm) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.closeCharActions();
            })
          Column() {
            Text(this.charActionName())
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 18, bottom: 10 })
            this.MsgActionRow('编辑', () => {
              this.editFromCharActions();
            })
            this.MsgActionRow('删除', () => {
              this.askDeleteChar();
            })
            Button('取消')
              .width('92%')
              .height(44)
              .backgroundColor(skinColor('chat_fill'))
              .fontColor(skinColor('text_primary'))
              .borderRadius(14)
              .margin({ top: 8, bottom: 16 })
              .onClick(() => {
                this.closeCharActions();
              })
          }
          .width('100%')
          .backgroundColor(skinColor('chat_surface'))
          .borderRadius({ topLeft: 28, topRight: 28 })
          .border({ width: 1, color: skinColor('chat_border') })
          .transition(TransitionEffect.translate({ y: 360 }).animation({ duration: 320, curve: Curve.ExtremeDeceleration }))
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
        .transition(TransitionEffect.opacity(0).animation({ duration: 280, curve: Curve.EaseOut }))
      }

      // ── 11. 角色卡删除二次确认（复用组件） ──
      ConfirmDialog({
        show: this.showCharDeleteConfirm,
        title: '确认删除该角色卡？',
        message: this.charActionName(),
        confirmText: '删除',
        danger: true,
        onConfirm: () => {
          this.confirmDeleteChar();
        },
        onCancel: () => {
          this.cancelDeleteChar();
        }
      })

    }
    .width('100%')
    .height('100%')
  }

  /** 首屏空态：品牌标识 + 一句随时段变化的问候（不放任何说明性文案）。 */
  @Builder
  EmptyChatState() {
    Column() {
      Image($r('app.media.deepseek'))
        .width(30)
        .height(30)
        .objectFit(ImageFit.Contain)

      Text(this.greetingText())
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor(skinColor('text_title'))
        .textAlign(TextAlign.Center)
        .margin({ top: 12 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 32, right: 32, bottom: 24 })
  }

  @Builder
  MsgActionRow(title: string, onTap: () => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .layoutWeight(1)
      Text('›')
        .fontSize(20)
        .fontColor(skinColor('icon_muted'))
    }
    .width('92%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .margin({ bottom: 6 })
    .backgroundColor(skinColor('chat_surface_alt'))
    .borderRadius(12)
    .onClick(onTap)
  }

  /** 附件来源面板：拍照 / 相册 / 文件（对齐官方底栏），选中后立刻上传解析。 */
  @Builder
  AttachSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showAttachSheet = false;
        })

      Column() {
        Row() {
          Text('添加图片或文件')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(15)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showAttachSheet = false;
            })
        }
        .width('92%')
        .margin({ top: 14, bottom: 14 })

        Row() {
          this.AttachTile($r('app.media.ic_camera'), '拍照', () => {
            this.attachFromCamera();
          })
          this.AttachTile($r('app.media.ic_gallery'), '相册', () => {
            this.attachFromGallery();
          })
          this.AttachTile($r('app.media.ic_attach'), '文件', () => {
            this.attachFromFiles();
          })
        }
        .width('92%')
        .justifyContent(FlexAlign.SpaceBetween)
        .margin({ bottom: 26 })
      }
      .width('100%')
      .backgroundColor(skinColor('chat_surface'))
      .borderRadius({ topLeft: 28, topRight: 28 })
      .border({ width: 1, color: skinColor('chat_border') })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  AttachTile(icon: Resource, label: string, onTap: () => void) {
    Column() {
      Image(icon)
        .width(26)
        .height(26)
      Text(label)
        .fontSize(13)
        .fontColor(skinColor('text_primary'))
        .margin({ top: 8 })
    }
    .width('30%')
    .height(88)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(skinColor('chat_fill'))
    .borderRadius(18)
    .onClick(onTap)
  }

  // ── 消息气泡子组件（高度对齐 DeepSeek 官方设计） ──
  @Builder
  MessageBubble(msg: ChatMessage) {
    if (msg.role === 'user') {
      Row() {
        Blank()
        Column() {
          // 文档附件（DeepSeek Files API）：图片直接显示缩略图（点了全屏预览），其余只展示文件名。
          if (msg.attachments !== undefined && msg.attachments.length > 0) {
            Column() {
              ForEach(msg.attachments, (att: MessageAttachment) => {
                if (att.localUri !== undefined && att.localUri.length > 0) {
                  Image(this.imageSrc(this.attachThumb(att)))
                    .width(150)
                    .height(150)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(14)
                    .margin({ bottom: 6 })
                    .onError(() => {
                      hilog.warn(DOMAIN, TAG, 'thumb load failed: %{public}s', this.attachThumb(att));
                    })
                    .onClick(() => {
                      this.previewImage = this.attachThumb(att);
                    })
                } else {
                  Row() {
                    Image($r('app.media.ic_attach'))
                      .width(13)
                      .height(13)
                      .margin({ right: 4 })
                    Text(att.fileName)
                      .fontSize(12)
                      .fontColor(skinColor('chat_user_text'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .constraintSize({ maxWidth: 200 })
                  }
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .backgroundColor(skinColor('chat_user_bubble'))
                  .borderRadius(10)
                  .margin({ bottom: 4 })
                }
              }, (att: MessageAttachment) => att.fileId)
            }
            .alignItems(HorizontalAlign.End)
          }
          // 用户气泡：官方蓝白版式（淡蓝底、右下收角），不描边，避免大色块打断阅读。
          // 纯附件消息没有文字，不再渲染空气泡。
          if (msg.content.length > 0) {
            Text(msg.content)
              .fontSize(16 * this.appFontScale)
              .fontColor(skinColor('chat_user_text'))
              .lineHeight(23 * this.appFontScale)
              .padding({ left: 18, right: 18, top: 12, bottom: 12 })
              .backgroundColor(skinColor('chat_user_bubble'))
              .borderRadius({ topLeft: 22, topRight: 22, bottomRight: 6, bottomLeft: 22 })
          }
          // @ 对象
          if (msg.mentionedIds.length > 0) {
            Text(this.mentionText(msg))
              .fontSize(11)
              .fontColor(skinColor('reasoning_muted'))
              .margin({ top: 4 })
          }
          // 分支切换
          if (this.branchCount(msg) > 1) {
            Row() {
              Blank()
              this.BranchSwitcher(msg)
            }
            .width('100%')
            .margin({ top: 4 })
          }
        }
        .alignItems(HorizontalAlign.End)
        .constraintSize({ maxWidth: '82%' })
        .gesture(LongPressGesture({ repeat: false }).onAction(() => {
          this.openMsgActions(msg.id);
        }))
      }
      .width('100%')
    } else {
      Row() {
        Column() {
          // 深度思考折叠条以轻量文字层级与细线装饰，保持长对话阅读节奏。
          if (msg.reasoningContent && msg.reasoningContent.length > 0) {
            Column() {
              // 标题栏：整行可点（44px 级触区），负责状态展示和点击切换
              Row() {
                if (this.isMsgThinkingStreaming(msg)) {
                  LoadingProgress()
                    .width(14)
                    .height(14)
                    .color(skinColor('reasoning_text'))
                    .margin({ right: 6 })
                }
                Text(this.reasonDisplayTitle(msg))
                  .fontSize(14)
                  .fontColor(skinColor('reasoning_text'))
                  .fontWeight(FontWeight.Normal)

                // 箭头旋转动效（折叠 0 度指向右，展开 90 度指向下）；加大内边距保触区
                Text('›')
                  .fontSize(14)
                  .fontColor(skinColor('reasoning_muted'))
                  .fontWeight(FontWeight.Medium)
                  .margin({ left: 2 })
                  .padding({ left: 8, right: 8, top: 8, bottom: 8 })
                  .rotate({ angle: this.isReasonCollapsed(msg.id) ? 0 : 90 })
                  .animation({ duration: 250, curve: Curve.FastOutSlowIn })
              }
              .alignItems(VerticalAlign.Center)
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .onClick(() => {
                this.toggleReason(msg.id);
              })

              // 内容区：带高度过渡动画与左侧装饰线，使用 onAreaChange 监听尺寸变化
              Row() {
                Column()
                  .width(2)
                  .backgroundColor(skinColor('reasoning_bar'))
                  .borderRadius(1)
                  .margin({ right: 10, top: 4, bottom: 4 })

                Scroll(this.thinkScrollerFor(msg.id)) {
                  Text(msg.reasoningContent)
                    .fontSize(13 * this.appFontScale)
                    .fontColor(skinColor('reasoning_text'))
                    .lineHeight(20 * this.appFontScale)
                    .width('100%')
                }
                .scrollBar(BarState.Auto)
                .constraintSize({ maxHeight: 380 })
                .layoutWeight(1)
              }
              .width('100%')
              .padding({
                left: 2,
                right: 6,
                top: this.isReasonCollapsed(msg.id) ? 0 : 6,
                bottom: this.isReasonCollapsed(msg.id) ? 0 : 10
              })
              .alignItems(VerticalAlign.Top)
              .clip(true)
              .opacity(this.isReasonCollapsed(msg.id) ? 0 : 1)
              .constraintSize({ maxHeight: this.isReasonCollapsed(msg.id) ? 0 : 450 })
              .animation({ duration: 250, curve: Curve.FastOutSlowIn })
              .onAreaChange((oldArea: Area, newArea: Area) => {
                this.onThinkingAreaChange(msg.id, Number(oldArea.height), Number(newArea.height));
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ bottom: 8 })
          }

          // 正文回复：FluidMarkdown 原生渲染（GFM）；流式中走 Typing 增量，完成后走 Normal。
          // Reason: key 已去掉 content/reasoning 长度（稳定实例防闪烁），文本经父重建下发，
          //   流式帧由库内 hash 差量 + 打字机 pacing 消化。
          if (msg.content.length > 0) {
            MarkdownBody({
              content: this.renderContent(msg),
              streaming: this.isLiveStreaming(msg),
              fontScale: this.appFontScale,
              darkMode: this.isDarkMode(),
              controller: this.mdControllers.get(msg.id),
              onLinkClick: (href: string) => {
                this.onMarkdownLink(href, msg);
              },
              onImageClick: (src: string) => {
                this.onMarkdownImage(src);
              },
              onMdResize: () => {
                // 门控在 scheduleAnchor 内：非生成态/已接管/已锚定一律直接返回，不拽视口。
                this.scheduleAnchor(msg.id);
              },
              onTypingReady: () => {
                this.onMarkdownReady(msg.id);
              },
            })
            .width('100%')
          } else if (msg.status === 'streaming') {
            Row() {
              LoadingProgress().width(18).height(18).color(skinColor('chat_accent'))
              Text(`  ${this.generationHint(msg)}`)
                .fontSize(14)
                .fontColor(skinColor('reasoning_text'))
            }
          }

          // 错误信息显示
          if (msg.status === 'error' && msg.errorMessage) {
            Text(`失败: ${msg.errorMessage}`)
              .fontSize(12)
              .fontColor(skinColor('danger_text'))
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(skinColor('danger_fill'))
              .borderRadius(10)
              .margin({ top: 6 })
          }

          // 截断提示（finish_reason=length）：正文已保留，只说明它可能不完整。
          if (msg.incomplete === true) {
            Text('回答达到长度上限，可能不完整')
              .fontSize(11)
              .fontColor(skinColor('text_secondary'))
              .margin({ top: 6 })
          }

          // 生图结果模块：进度 / 元数据条 / 成图 / 操作行 / 失败重试。
          if (msg.imageState === 'generating') {
            Row() {
              LoadingProgress().width(15).height(15).color(skinColor('chat_accent'))
              Text(`  ${msg.imageHint !== undefined ? msg.imageHint : '正在生成图片…'}`)
                .fontSize(12)
                .fontColor(skinColor('text_secondary'))
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ top: 8 })
          } else if (msg.imageState === 'failed') {
            Column() {
              Text(`生图失败：${msg.imageHint !== undefined ? msg.imageHint : '未知原因'}`)
                .fontSize(12)
                .fontColor(skinColor('danger_text'))
                .width('100%')
              if (msg.imagePrompt !== undefined && msg.imagePrompt.length > 0) {
                Text('重试')
                  .fontSize(12)
                  .fontColor(skinColor('chat_accent'))
                  .padding({ top: 6 })
                  .onClick(() => {
                    this.retryImage(msg);
                  })
              }
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .backgroundColor(skinColor('danger_fill'))
            .borderRadius(10)
            .margin({ top: 6 })
          }
          if (msg.imageUrls !== undefined && msg.imageUrls.length > 0) {
            // 元数据条：模型 | 比例 | 画质 | 耗时（低饱和小字，紧贴成图上方）。
            if (msg.imageMeta !== undefined && msg.imageMeta.length > 0) {
              Text(msg.imageMeta)
                .fontSize(11)
                .fontColor(skinColor('text_muted'))
                .width('100%')
                .margin({ top: 8, bottom: 6 })
            }
            Column({ space: 8 }) {
              ForEach(msg.imageUrls, (url: string) => {
                // 直接展示成图：不套卡片、不加边框/底色，宽度撑满后由图片自身比例决定高度。
                Image(url)
                  .width('100%')
                  .objectFit(ImageFit.Contain)
                  .borderRadius(12)
                  .onClick(() => {
                    this.previewImage = url;
                  })
              }, (url: string) => url)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // 轻量操作行：预览 / 复制链接 / 浏览器打开（移动端无 hover，常驻显示）。
            Row({ space: 16 }) {
              Text('预览')
                .fontSize(12)
                .fontColor(skinColor('text_secondary'))
                .onClick(() => {
                  if (msg.imageUrls !== undefined && msg.imageUrls.length > 0) {
                    this.previewImage = msg.imageUrls[0];
                  }
                })
              Text('复制链接')
                .fontSize(12)
                .fontColor(skinColor('text_secondary'))
                .onClick(() => {
                  this.copyImageLink(msg);
                })
              Text('浏览器打开')
                .fontSize(12)
                .fontColor(skinColor('text_secondary'))
                .onClick(() => {
                  if (msg.imageUrls !== undefined && msg.imageUrls.length > 0) {
                    this.openExternalUrl(msg.imageUrls[0]);
                  }
                })
            }
            .width('100%')
            .margin({ top: 6 })
          }
          // 联网搜索来源：官方同款胶囊（站点图标堆叠 + N 个网页），点开在下方展开明细。
          if (this.sourcesOf(msg).length > 0) {
            this.SourcePill(msg)
            if (this.expandedSourceMsgId === msg.id) {
              this.SourceList(msg)
            }
          }

          // 回答操作条：复制 / 朗读（再点即打断）/ 重新生成，位置对齐官方 App。
          if (msg.status !== 'streaming') {
            this.AnswerActions(msg)
          }

          // 分支切换
          if (this.branchCount(msg) > 1) {
            Row() {
              Blank()
              this.BranchSwitcher(msg)
            }
            .width('100%')
            .margin({ top: 6 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 4, right: 4, top: 4, bottom: 6 })
      }
      .width('100%')
    }
  }

  /**
   * 来源胶囊（对齐官方 App）：左侧 3 个站点图标叠放，右侧「N 个网页」，点一下展开明细。
   * Business Rule: 图标失败不能留空——底层先画站点首字母，网络图标盖在它上面。
   */
  @Builder
  SourcePill(msg: ChatMessage) {
    Row() {
      Row() {
        ForEach(this.pillSources(msg), (src: SearchSource, idx: number) => {
          Stack() {
            Text(WebSearchService.sourceSite(src).substring(0, 1).toUpperCase())
              .fontSize(9)
              .fontColor(skinColor('text_muted'))
              .width(18)
              .height(18)
              .textAlign(TextAlign.Center)
              .backgroundColor(skinColor('chat_fill'))
              .borderRadius(9)
            if (src.siteIcon !== undefined && src.siteIcon.length > 0) {
              Image(src.siteIcon)
                .width(18)
                .height(18)
                .borderRadius(9)
                .objectFit(ImageFit.Cover)
            }
          }
          .width(18)
          .height(18)
          .borderRadius(9)
          .border({ width: 1.5, color: skinColor('chat_surface') })
          .margin({ left: idx === 0 ? 0 : -6 })
        }, (src: SearchSource) => src.url)
      }
      .alignItems(VerticalAlign.Center)

      Text(`${this.sourcesOf(msg).length} 个网页`)
        .fontSize(13)
        .fontColor(skinColor('text_secondary'))
        .margin({ left: 8 })

      Text('›')
        .fontSize(13)
        .fontColor(skinColor('text_faint'))
        .margin({ left: 4 })
        .rotate({ angle: this.expandedSourceMsgId === msg.id ? 90 : 0 })
        .animation({ duration: 200, curve: Curve.FastOutSlowIn })
    }
    .height(38)
    .padding({ left: 10, right: 14 })
    .backgroundColor(skinColor('chat_surface'))
    .border({ width: 1, color: skinColor('chat_border') })
    .borderRadius(19)
    .margin({ top: 10 })
    .onClick(() => {
      this.toggleSourcePanel(msg.id);
    })
  }

  /**
   * 联网搜索来源列表（对齐官方 App 的来源卡片）：序号 + 标题 + 站点名，点击打开原网页。
   * Business Rule: 序号即引用序号（1 起），与正文 [ref_N] 改写后的 #cite-N 一一对应，
   *   因此来源顺序必须与 WebSearchService.mergeSources 的合并顺序一致，不得在此重排。
   */
  @Builder
  SourceList(msg: ChatMessage) {
    Column() {
      Row() {
        Text('来源')
          .fontSize(12)
          .fontColor(skinColor('text_secondary'))
          .fontWeight(FontWeight.Medium)
        Text(`${this.sourcesOf(msg).length}`)
          .fontSize(11)
          .fontColor(skinColor('text_faint'))
          .margin({ left: 6 })
      }
      .width('100%')
      .margin({ bottom: 2 })

      ForEach(this.sourcesOf(msg), (src: SearchSource, idx: number) => {
        Row() {
          Text(`${idx + 1}`)
            .fontSize(11)
            .fontColor(skinColor('chat_accent'))
            .textAlign(TextAlign.Center)
            .width(18)
            .height(18)
            .backgroundColor(skinColor('chat_accent_soft'))
            .borderRadius(9)
            .margin({ right: 8 })
          Column() {
            Text(src.title.length > 0 ? src.title : src.url)
              .fontSize(12 * this.appFontScale)
              .fontColor(skinColor('text_primary'))
              .lineHeight(17 * this.appFontScale)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(WebSearchService.sourceSite(src))
              .fontSize(10)
              .fontColor(skinColor('text_faint'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 7, bottom: 7 })
        .onClick(() => {
          this.openExternalUrl(src.url);
        })
      }, (src: SearchSource) => src.url)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 10, bottom: 4 })
    .margin({ top: 8 })
    .backgroundColor(skinColor('chat_surface_alt'))
    .borderRadius(12)
  }

  /** 回答操作条上的单个图标按钮：34×30 触区，朗读中（active）用柔色底提示可打断。 */
  @Builder
  AnswerAction(icon: Resource, active: boolean, disabled: boolean, onTap: () => void) {
    Row() {
      Image(icon)
        .width(16)
        .height(16)
        .opacity(disabled ? 0.35 : 1)
    }
    .width(34)
    .height(30)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(15)
    .backgroundColor(active ? skinColor('chat_accent_soft') : '#00000000')
    .onClick(() => {
      if (!disabled) {
        onTap();
      }
    })
  }

  /**
   * 回答操作条（对齐官方 App 的位置）：复制 / 朗读 / 重新生成。
   * Business Rule: 朗读与打断朗读是同一个按钮——正在朗读时按钮高亮，再点即停止
   *   （长按菜单不再承载助手消息的操作，打断朗读必须有可见入口）。
   */
  @Builder
  AnswerActions(msg: ChatMessage) {
    Row() {
      this.AnswerAction($r('app.media.ic_copy'), false, msg.content.length === 0, () => {
        this.copyMessage(msg);
      })
      if (this.featureTts) {
        this.AnswerAction($r('app.media.ic_speaker'), this.isReading(msg.id), msg.content.length === 0, () => {
          this.toggleReadAloud(msg);
        })
      }
      Blank()
      this.AnswerAction($r('app.media.ic_refresh'), false, false, () => {
        this.regenerateFrom(msg);
      })
    }
    .width('100%')
    .margin({ top: 4 })
    .padding({ left: 0, right: 2 })
  }

  // 分支切换控件：< i/n >，仅在存在多个版本时由调用方渲染；箭头加大内边距保触区。
  @Builder
  BranchSwitcher(msg: ChatMessage) {    Row() {
      Text('‹')
        .fontSize(18)
        .fontColor(skinColor('chat_accent'))
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .onClick(() => {
          this.switchBranch(msg, -1);
        })
      Text(`${this.branchIndex(msg) + 1}/${this.branchCount(msg)}`)
        .fontSize(12)
        .fontColor(skinColor('text_secondary'))
      Text('›')
        .fontSize(18)
        .fontColor(skinColor('chat_accent'))
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .onClick(() => {
          this.switchBranch(msg, 1);
        })
    }
    .backgroundColor(skinColor('chat_surface'))
    .border({ width: 1, color: skinColor('chat_border') })
    .borderRadius(14)
  }
}





