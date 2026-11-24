---
covered_paths:
  - BalanceApp/entry/src/main/ets/services/BalanceService.ets
  - BalanceApp/entry/src/main/ets/services/ProviderRegistry.ets
  - BalanceApp/entry/src/main/ets/services/ChatService.ets
  - BalanceApp/entry/src/main/ets/services/MarkdownService.ets
  - BalanceApp/entry/src/main/ets/components/MarkdownBody.ets
  - BalanceApp/entry/src/main/ets/models/ChatModels.ets
  - BalanceApp/entry/src/main/ets/pages/Index.ets
  - BalanceApp/entry/src/main/ets/pages/ChatView.ets
  - BalanceApp/entry/src/main/ets/pages/Settings.ets
  - BalanceApp/entry/src/main/ets/pages/Assets.ets
  - BalanceApp/entry/src/main/ets/services/AuthService.ets
  - BalanceApp/entry/src/main/ets/services/SettingsService.ets
  - BalanceApp/entry/src/main/ets/services/ChatStorageService.ets
  - BalanceApp/entry/src/main/ets/services/ChatMessageDataSource.ets
  - BalanceApp/entry/src/main/ets/components/AppLockGate.ets
  - BalanceApp/entry/src/main/ets/components/ConfirmDialog.ets
  - BalanceApp/entry/src/main/ets/components/ThinkingButton.ets
  - BalanceApp/entry/src/main/ets/entryability/EntryAbility.ets
  - BalanceApp/entry/src/main/resources/base/profile/main_pages.json
  - BalanceApp/entry/src/main/resources/base/element/color.json
  - BalanceApp/entry/src/main/resources/dark/element/color.json
  - BalanceApp/entry/src/main/resources/base/media/ic_appearance.svg
  - BalanceApp/entry/src/main/resources/base/media/ic_assets.svg
  - BalanceApp/entry/src/main/resources/base/media/ic_collapse.svg
  - BalanceApp/entry/src/main/resources/base/media/ic_expand.svg
  - BalanceApp/entry/src/main/resources/base/media/ic_font.svg
  - BalanceApp/entry/src/main/resources/base/media/ic_language.svg
  - BalanceApp/entry/src/main/resources/base/media/ic_personalize.svg
  - BalanceApp/entry/src/main/ets/services/WebSearchService.ets
  - BalanceApp/entry/src/main/ets/components/WebSearchButton.ets
  - BalanceApp/entry/src/main/ets/services/TtsService.ets
last_verified_commit: c6e5c02
last_verified: 2026-11-24
---

> 前瞻设计：多角色群聊（@ + 记忆隔离）详见 `docs/group-chat-design.md`（原设计中的 Jev 路由已随
> 上下文净化移除，见下方「已移除」小节）。
> 状态：群聊已下线（相关代码注释保留，运行时恒为单聊）；以下“群聊 Phase 1”小节为历史记录。
> 跨平台移动端（Android/iOS，Flutter）见 `systemmap/balance-app-mobile.md`，与鸿蒙端并列维护。

## 百智云积分与签到跳转（2026-11-24，构建通过）

- **为什么要单独一条引擎**：百智云钱包 `GET /api/v1/user/wallet/balance` 只认浏览器会话
  Cookie（`baizhi_session`，WAF 还要求 UA 与取 Cookie 的浏览器一致），没有 API Key 通道。
  故 `BalanceQueryType` 增加 `CookieSession`，`BalanceService` 拆三层：`requestText`（GET 通道 +
  状态码收敛成三通道）、`parseBody`（通用解析）、`queryBearer` / `queryCookieSession`（只拼头）。
  Bearer 与 Cookie 共用同一份解析，避免两套字段映射漂移。
- **注册表扩展**：`ProviderDefinition` 新增 `credentialKind` / `credentialRequiredFragment` /
  `checkinUrl`；`BalanceQueryConfig` 新增 `userAgent` 与四个积分明细字段。加 Cookie 类厂商
  仍是纯数据（协议本身还是 JSON）。
- **积分口径**：接口金额单位是「分」，`amountMultiplier: 0.01` 换算成积分（73500 → 735）。
  币种位用占位符 `CREDITS`：`currencySymbol` 返回空串、`unitLabel` 返回「积分」，
  Hero 仍按 `currency` 分组，人民币与积分不会相加；两者混排时标题写「多单位组合」。
  卡片额外展示「临时 / 永久 / 冻结」与今日是否已领取。
- **签到只能跳转**：签到接口触发验证码，应用不代签，只用
  `startAbility({action:'ohos.want.action.viewData'})` 打开 `https://baizhi.cloud/console/apps`。
  卡片按钮「去签到」（已领取则置灰「今日已签到」），长按菜单也有入口；浏览器里签完回来点卡片
  刷新即可看到 `daily_temporary_credit_claimed` 与临时积分变化。
- **边界校验**：空 Cookie、缺 `baizhi_session` 在本地直接拒绝；粘贴带上的 `Cookie:` 前缀与
  换行由 `normalizeCredential` 归一化；日志对 Cookie 只记长度（`maskCredential`），不落明文。
- **验证**：`hvigor assembleHap` 通过（clean build）。解析与边界语义由移动端同构实现的单元
  测试覆盖（`mobile/test/balance_service_test.dart`）；真实接口需用户自己的 Cookie，见
  `techdebt/TD-009`。

## 阅读链接与用户元信息（2026-11-23，构建通过）

- **阅读链接 `deepseek_read_url`**：`ChatRequestOptions.enableReadUrl` 为真、服务商是 DeepSeek 时下发
  `tools:[{type:'deepseek_read_url'}]`；设置>工具「阅读链接」开关默认开（`feature_read_url`）。
  官方语义：**开思考且同时声明了搜索时走深度思考搜索、本轮不读链接**；只有关思考或未声明搜索才读
  最后一条用户消息里的 URL（最多前 10 个）。
- 解析 `services/WebSearchService.ets`：`parseToolEvent` 放行 `kind=read_link`，并把 `call.page`
  （url/title/published_at）转成来源卡片；`startedLabel` 补「正在阅读链接…」。
- **回传是关键**：网页正文不在块里，加密在 `web_fetch_tool_result.signature`（Chat Completions 是
  `call.signature`）；完整 `server_tool_calls` 只在带 `finish_reason` 的末块 `delta.server_tool_calls`
  一次性下发。`ChatService` 用 `serializeServerToolCalls` 校验（结构 + 200KB/条上限）后以原文存
  `ChatMessage.serverToolCallsJson`（持久化），`buildApiMessages` 原样放回 assistant 消息的
  `server_tool_calls`。**只读了链接、没吐正文的回合也必须保留**，否则 signature 会随空回合一起丢掉。
- 边界：`tools` 里的联网工具不能与生图等客户端工具以外的服务端工具混用、跨服务商声明会 400，故只对
  DeepSeek 生效；带工具块的历史发给未声明工具的请求是合法的（官方允许）。
- **用户元信息 `latest_reminder`**：`ChatService.buildApiMessages` 给**每条 user 消息前**插一条
  `{role:'latest_reminder', content:'<date>,<weekday>,<location>,App,<language>'}`。
  日期取该条消息 `createdAt`（回放历史时每轮仍是当天），星期随界面语言（星期一 / Monday），
  `language` 用语言自称（中文 / English），`location` 可留空、可含逗号。
  只对 DeepSeek 注入（其他服务商不认该 role，会 400）。所在地在设置>工具里填，
  `sanitizeLocation`（`models/ChatModels.ets`）收口换行与 40 字上限。
- 历史截断改为按「历史单位」做：1 条 user + 1 条 reminder 视为一个单位，条数/字符预算都不会把
  reminder 和它所属的 user 消息拆开（协议要求紧邻）。
- 验证：`hvigor assembleHap` 构建通过。2026-11-23 真机（6UNBB26820047956）联调：阅读链接
  主链路通（`server_tool_calls: 2239 chars`、来源「1 个网页」），签名随历史回传经日志
  确认为 `replay: 1 turns`；`latest_reminder` 答出「2026年11月23日，星期一」。
  联调中发现并修复历史投影漏拷 `serverToolCallsJson`（`46f2601`）。
  服务端是否真正还原网页、以及思考+搜索组合等未测项见 `techdebt/TD-007`。

## 主题体系：多皮肤运行时切换（2026-11-20，构建通过）

- 问题：配色全是 `resources/base/element/color.json` 的编译期常量，`$r('app.color.x')` 无法运行时整体替换，
  用户没得选，两端观感还不一致。
- 切割：颜色从「资源层」搬到「运行时调色板层」。`services/SkinService.ets` 持有 4 套风格
  （official 官方蓝白 / paper 暖纸墨金 / jade 青黛 / ink 石墨），每套含 light + dark 两份调色板；
  组件统一调 `skinColor('token')`，未知 token 回退官方浅色，绝不返回空色（空色 = 组件透明）。
- 刷新链路：皮肤或明暗一变 → `AppStorage['skin_version']++` → 所有声明 `@StorageProp('skin_version')`
  的组件重绘。**新增组件若用到 skinColor，必须补这一行，否则切换主题时它不会刷新。**
- 明暗与风格是两个正交维度：`SettingsService` 仍负责 system/light/dark 并落 `KEY_APP_DARK`，
  皮肤侧只调 `syncDarkMode(bool)`；冷启动在 `EntryAbility.onWindowStageCreate` 里、首帧之前 `initSkin`。
- 数据形态：`SkinPalette` 用 `token=#hex,token=#hex` 紧凑串在构造时展开成 Map
  （ArkTS 严格模式禁无类型对象字面量，50 字段写类又太重）；新增 token 只改数据。
- 迁移面：453 处 `$r('app.color.*')` → `skinColor('*')`，7 个 struct 各补一行 `@StorageProp`。
- 遗留：`resources/dark/element/color.json` 与 color.json 里未迁移的历史 token 已不参与渲染，
  仅 `start_window_background` 仍由资源提供；下次清理时一并删除。

## 历史侧栏对齐官方（2026-11-20，构建通过）

- 现象（用户截图）：抽屉是浮层，却画在安全区内 —— 状态栏与导航条区域露出页面底色，
  上下各多一条白边，圆角+投影被切在中间；底部「角色管理/设置」图标只剩一个 2vp 小点。
- 铺满整屏的做法：蒙层与面板底色各用一层**无子组件的背景 Column** 加
  `expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])`。
  Reason：expandSafeArea 只影响绘制区域，放在纯背景层上时内容层仍留在安全区内 ——
  头部不会被状态栏压住，末项也不会压在 home indicator 上；反过来给带内容的容器加，
  子元素会一起被顶到状态栏底下。
- 视觉：新增 `sidebar_surface`(#F1F2F4)，面板由白底浮层改整屏浅灰；去圆角与投影；
  会话行改扁平行（去描边卡片，行距 2vp，左右 18vp 与头部左对齐），选中项用白底浮起。
- 头部：由「历史会话」标题行改为搜索框 + 「+ 新会话」（官方同版式）。
  搜索走 `@State sessionQuery` + `filteredSessions()`（只匹配标题，大小写不敏感）；
  抽屉子树随 `if (this.showDrawer)` 卸载，故 `openDrawer()` 每次清空关键词。
- 坑位：`Image(...).width(18).height(18).padding(8)` 会把图片内容压成 18-16=2vp，
  图标必须「34vp 圆底容器 + 居中 18vp 图标」两层写。
- 打开抽屉前 `getFocusController().clearFocus()` 收输入法：整屏浮层 + 键盘会把窗口压扁。

## 附件缩略图（2026-11-20，构建通过）

- 现象：上传图片后，输入框和已发送气泡都只显示 `IMG_xxx.jpg` 文件名胶囊，看不到图。
- 做法：选图时把图片复制到 `filesDir/attachments/<时间戳>_<名>`（picker URI 是临时授权，
  重启后读不到），路径存进 `MessageAttachment.localUri`（可选字段，随会话持久化）。
- 展示：输入框待发送胶囊显 26×26 缩略图；已发送用户气泡显 150×150 圆角缩略图，
  点击复用 `previewImage` 全屏预览；非图片附件仍走文件名胶囊。
- 已知欠账：删会话不会清理 `filesDir/attachments` 下的副本（会慢慢堆积），后续按会话 id 归档或 GC。

- 现象：生图之后每一轮都在重复生图——问「我手里这是什么」（带图追问）被当成还要生成头像；
  问「搜一搜日照有哪些景点」也只调了生图工具，正文回「我没有联网搜索工具」。
- 根因 1（上下文污染）：模型只调 `generate_image` 时，助手回合 `content` 为空、只有 `reasoningContent`。
  `buildApiMessages` 原先用 `hasReasoning` 放行这种空回合，并且对 DeepSeek 也回传 `reasoning_content`。
  模型于是认为「上一条用户请求还没被回答」，每轮都重放旧生图指令。
  修：① 助手空回合不再回传（带图的旧回合用「（已为你生成图片）」占位结算）；
  ② `reasoning_content` 只对 Kimi / 小米 MiMo（Preserved Thinking）回传，DeepSeek 一律丢弃；
  ③ 生图成功后若正文为空，补一句「已为你生成图片。」，让该回合在历史里算已作答。
- 根因 2（工具互斥）：同场声明 `deepseek_web_search` 与 `generate_image` 时，模型经常只认生图工具，
  并声称自己没有搜索能力。实测同一条 history：只给 web 工具必检索，两个都给则不检索。
  修：按意图二选一——`ChatView.wantsImage()` 命中关键词（画/头像/海报/插画/配图/壁纸/生图/绘制…）
  才声明 `generate_image`，否则只声明 `web_search`。
- 验证（真实 Key 重放历史）：修前「搜日照」→ 返回 `generate_image` 工具调用；修后 → 直接检索并返回 19 条引用；
  「我手里这是什么」+ 仅 web 工具 → 正常答出贝壳/卵石/螺壳并检索 9 条引用。

## 首屏空态对齐官方（2026-11-20，构建通过）

- 请求：首屏去掉装饰性文案（原「BALANCE / AI」眉标、「让想法慢慢展开」标语、
  「从一个问题开始…」副标题），只留品牌标识 + 一句随时段变化的问候。
- 实现：`ChatView.EmptyChatState()`（`@Builder`）= `deepseek.png` 56×56 + 问候语
  22 号 Medium；文案走 `I18nService` 新增键 `chat_greeting_morning/afternoon/evening/night`
  （zh/en 各一套），时段 5–11 早上 / 12–17 下午 / 18–22 晚上 / 23–4 夜深。
- 连带：`ChatView` 新增 `@StorageProp('app_language')`，切换语言时问候语立即重绘；
  空态下顶栏隐藏会话标题与服务商副标题，模型胶囊去掉「选模型」提示。
- 结构变化：消息区从「List 内 if 空态」改为 build 层 `if/else`，空态用
  `layoutWeight(1)` 在剩余区域垂直居中（原实现固定 340 高、贴顶）。

## 语音输入（ASR，2026-11-19，构建通过）

- 交互（`9d0c826`）：两种输入形态，对齐官方——
  - 文字模式（默认）：占位「发消息或按住说话」，输入为空时右侧是麦克风（点击切语音模式）；
    有文字/就绪附件即显示发送；生成中显示停止。
  - 语音模式：整块输入区变成「按住说话」，按下开始、松开结束；右侧变键盘钮切回文字模式。
    录音中显示「松开结束 0:12」；转写成功自动切回文字模式并回填文本（不自动发送）。
    授权弹窗期间提前松手、或录音启动前松手，都会立即收尾，不会留下一直录的麦克风。
- 录音 `services/VoiceRecorder.ets`：AudioCapturer 16 kHz / 单声道 / S16LE / RAW；
  **录音期只写 .pcm，停止时新建 .wav 写 44 字节头再分块拷贝 PCM**。
  Reason: 早期"先占位 44 字节 + 停止时按 offset 回填头"在真机被服务端判 400（音频格式不支持），
  怀疑回填位置不可靠导致文件以 44 个 0 开头；分块拷贝不依赖 seek/offset 语义。
  上限 120 秒（16k×2B×120s≈3.8 MB，远低于 8 MiB）；`stop` 幂等，失败清残片，离开页面 `cancel`。
- 转写 `services/AsrService.ets`：multipart 只带 `file` 字段 POST `/v1/tools/asr`，解析 `text`；
  语种由服务端自动识别（无参数）；无论成败删除临时 WAV；400/413/429/503/504 映射成中文提示。
- 权限：`ohos.permission.MICROPHONE`（user_grant；module.json5 带 reason 与 usedScene），
  首次按住说话时 `requestPermissionsFromUser` 申请，拒绝则提示且不启动录音。
- 实测：TTS 生成的 wav（207 KB）打 `/v1/tools/asr` 返回
  「你好，我是DeepSeek，这是一次语音合成测试。」`duration_ms=4320`，端点与 multipart 形状正确；
  用手写的 16k/单声道/16bit 静音 WAV（32 KB）验证头部字段同样返回 200。
  计费按音频时长（0.78 元/小时，限时 5 折）。

## 文档问答（DeepSeek Files API，2026-11-19，构建通过）

- 上传 `services/FileUploadService.ets`：系统文件选择器（`DocumentViewPicker`）→ 把 URI 复制到
  `cacheDir` 临时文件 → `multipart/form-data POST https://api.deepseek.com/files`。
  **`purpose` 必须排在 `file` 之前**（官方硬要求，MultiFormData 数组顺序即字段顺序）；
  解析完成才返回 `file_id`，故 `readTimeout` 给到 300s（上传 120s + 解析 120s）。
  本地临时副本在 finally 删除；服务端限制 100 MiB（user_data 32 MiB）。
- purpose 选择：文本/表格/电子书（txt/md/csv/json/代码/xlsx/xls/epub/mobi）→ `user_data`
  （不解析、不计费）；PDF/Word/PPT → `text_recognition`（只取文字，不裁图，省图片额度）。
- **图片（视觉）**：png/jpg/jpeg/webp/gif 必须用 `user_data` 上传，再以 `{type:'file', file_id}`
  引用，模型才能看到画面；用 `text_recognition` 上传只会被 OCR 成文字——实测同一张深海鲸 logo：
  `user_data` 答「蓝白配色的扁平化鲸鱼标志」，`text_recognition` 只答「数字 1」。
  bmp/tiff 视觉不支持，仍走 `text_recognition`。官方视觉限制：单图 base64/URL 32 MiB、
  `file_id` 64 MiB、单请求最多 600 张、请求体 48 MiB。
- 附件三来源（底部面板）：拍照（`cameraPicker`，系统相机，不需要应用申请相机权限）、
  相册（`PhotoViewPicker` 多选，最多补满 3 个）、文件（`DocumentViewPicker`）。
- 失败诊断：上传失败会打 hilog（`FileUploadService`，含文件名与 purpose），
  真机 toast 一闪而过时用 `hilog -x -t app` 定位。
- 引用：`ChatMessage.attachments`（fileId/fileName/purpose/bytes）持久化；
  `ChatService.buildApiMessages` 对 user 消息生成 `content:[{type:'file',file_id},{type:'text',text}]`，
  仅 DeepSeek 生效（其他服务商退回纯文本，避免 400）；纯附件消息不会因空文本被丢弃；
  编辑重发继承原附件；历史轮次按 `file_id` 原样回放（官方保证文档内容留在上下文）。
- UI：输入卡片「+」仅在 DeepSeek 可点（其他服务商半透明+提示），选中后立刻上传；
  卡片内显示「文件名 解析中…/文件名 ×」，解析期间禁止发送；单次最多 3 个文件（服务端上限 20）；
  用户气泡上方显示附件行（纸夹图标 + 文件名）。
- 实测：上传 txt（user_data）返回 `file-api-8401f188-…`；随后对话请求用 content 数组问
  「内部代号是什么」→ 正确答出文档里的「蓝鲸」，说明两步协议与字段顺序都正确。
- 已知边界：`file_id` 与账号绑定——换 DeepSeek Key 或换账号后旧附件的 `file_id` 失效，
  追问会 400/失败，需重新上传；界面暂无「重新上传」引导，后续按需补。

## 聊天页蓝白化（2026-11-19，构建通过）

- 范围：只切聊天页（ChatView + 两个能力胶囊组件 + Markdown 正文），设置页/资产页仍为暖金，
  用户选择分阶段迁移。新增 `chat_*` 语义色，base/dark 各一套：
  `chat_surface`(#FFFFFF/#1B1B1F)、`chat_surface_alt`、`chat_border`、`chat_fill`、
  `chat_user_bubble`(#E8EEFC/#26304F)、`chat_user_text`、`chat_accent`(#4D6BFE/#8FA6FF)、
  `chat_accent_soft`、`chat_accent_soft_selected`、`chat_accent_solid`、`chat_accent_contrast`、
  `chat_accent_outline`。
- 做法：ChatView 内原 `accent* / surface* / border_* / input_bg / icon_tile / fill / user_bubble_text`
  全部按 token 粒度替换为 `chat_*`（139 处），组件 ThinkingButton/WebSearchButton 的
  off 态底色改用 `chat_fill`。**不要改全局 accent**——那会连带设置/资产页。
- 版式：用户气泡 22/22/6/22 圆角、无描边、16 号字；消息区左右 20；思考条 14；来源胶囊
  38 高 / 19 圆角 / 13 号字；输入卡片 28 圆角、16 内边距、占位 16 号；卡片下方加
  「回答由 AI 生成，内容仅供参考」；能力胶囊 32 高。
- 顶栏：新增喇叭（朗读最后一条有正文的回答，朗读中柔蓝底高亮）与写消息（新建会话并直接
  进入角色选择，复用抽屉「+ 新会话」流程）两个入口；标题 16 号。
- 回答操作条图标由 #8A8578 加深到 #6A6C72（纯白底上更清楚）。
- 真机 dumpLayout 核对：`新对话` 标题、`深度思考`/`智能搜索` 胶囊（y≈2406）、
  底部说明（y≈2568）均在屏内，底边留白正常。

## 自动会话标题（2026-11-19，构建通过）

- 请求：Chat Completions 顶层加 `title:{enabled:true}`（DeepSeek 扩展字段，其他服务商透传会 400，
  故只在 `providerId === 'deepseek'` 时下发）。只在会话首轮请求上声明，服务端最多多等 5 秒，标题不计费。
- 响应：标题在最后一个 chunk 的 `delta.title`（非流式在 `message.title`），服务端可能不给
  （拒答/出错）——发送时就先写「用户消息前 14 字」兜底标题，拿到服务端标题再覆盖。
- 去重：`ChatSession.autoTitled`（持久化）在首轮成功完成后置 true，同一会话不再重复请求；
  `isAutoTitle` 保证用户手动重命名后不被覆盖。旧会话 normalize 缺省 false，升级后只会多试一次。
- 实测：`deepseek-flash` + `title` + `tools` 流式请求，最后一个 chunk 返回
  `delta.title:"北京明天降雨预报"`。注意响应里搜索结果项也有 `title` 字段，解析必须限定
  `choices[0].delta.title`，不能全文正则匹配，否则会取到网页标题。

## 输入卡片对齐官方（2026-11-19，构建通过）

- 形式：整块圆角输入卡片（`input_bg` 底 + 细边框 + 轻阴影），内含多行 TextArea（透明底、
  无边框、占位「发消息…」）、左下能力胶囊、右下发送/停止圆钮；展开/收起图标浮在输入区右上。
- 能力胶囊改为官方样式：`深度思考`（`ic_atom`）+ `智能搜索`（`ic_globe`，原「联网搜索」），
  淡蓝底 + 品牌蓝文字 + 细蓝边，关闭态为素灰底；新增语义色 `pill_search_bg/text/border`
  （base/dark 各一套）。开启态仍只决定是否下发 thinking / tools，行为未变。
- 已做：「+（附件）」接 DeepSeek Files API（见「文档问答」）；麦克风接语音输入（见「语音输入（ASR）」）。
  占位文案为「发消息，或点麦克风说话」。
- 注意：胶囊行现在在卡片内部，`ThinkingButton` / `WebSearchButton` 的外边距已改为 0（后者右 8），
  两个组件目前只在卡片这一处使用。

## 引用角标、来源胶囊与语音朗读（2026-11-19，构建通过）

- 引用角标（对齐官方 App 正文里的小数字）：`annotations` 的 `url_citation` 带
  `start_index`/`end_index`（**Unicode 码点**，不是 UTF-16 下标）。`WebSearchService.parseCitations`
  保留区间，`ChatMessage.citations` 持久化；渲染时 `MarkdownService.injectCitations` 把区间末尾
  换算成 UTF-16 下标后插入 `[N](#cite-N)`，点击落 `#cite-N` → 打开对应来源。
  - 围栏代码块内的区间不插（避免污染示例代码）；
  - 从后往前插，避免前面的插入挤动后面的下标；同位置多角标先插大序号，最终呈现 `[1][2]`；
  - 只在非流式（完成后）注入——流式中 `annotations` 还没到，且注入会让 Typing 增量跳变。
- 来源胶囊：`SourcePill` 用 3 个站点图标叠放 + 「N 个网页」，样式为白底细边框胶囊、宽度随内容；
  点一下在下方展开 `SourceList` 明细（再点收起）。图标先画站点首字母、网络图标盖在上面，
  图标加载失败不会留空。
  - **坑**：展开态是页面级 `@State`，不在消息数据里；LazyForEach 同 key 复用旧快照，
    必须把展开态写进 `msgRenderKey` 并显式 `syncMessageSource()`，否则点了没反应。
- 回到底部：由「↓ + 回到底部」文字胶囊改为 42vp 圆形图标按钮（`ic_scroll_down.svg`）。
- 语音朗读 `services/TtsService.ets`：
  - `POST https://api.deepseek.com/v1/tools/tts`，体 `{text, voice_id, format:'wav'}`，
    `expectDataType=ARRAY_BUFFER`；服务端默认 `filter_markdown=true`，客户端不清洗 Markdown；
    文本按 UTF-16 长度截断到 10000（服务端计费字符上限更宽松）。
  - **本地缓存**：音频写 `cacheDir/tts_cache/<FNV-1a(voice|text)>.wav`，同一段回答 + 同一音色
    只合成一次；停止播放**不删文件**，再次点朗读直接命中缓存播放——不发请求、不重复计费。
    先写 `.tmp` 再 rename，避免半截文件被当成缓存；缓存按 16 个 / 40MB 水位按 mtime 淘汰最旧。
  - 并发守卫：`pendingKey` 让同一段正在合成时的重复点击直接忽略；`callId`（复用 session 自增号）
    让旧请求回来时不再抢占播放器。
  - AVPlayer `fdSrc` 播放；completed/error 释放播放器与 fd 句柄。
  - Key 取 `key_deepseek`（TTS 是 DeepSeek 专属能力，与当前服务商无关），缺失时提示去资产监控配置。
  - 入口：回答下方操作条 `AnswerActions`（复制 / 朗读 / 重新生成，图标 `ic_copy`、`ic_speaker`、
    `ic_refresh`）——朗读与「打断朗读」是同一个按钮，播放中按钮以柔色底高亮；再点即停。
    长按助手消息不再弹菜单（只保留用户消息的「编辑并重发 / 复制」）。
    切换会话、新建会话、离开页面自动停；重新生成前也会先停。
- 设置页：新增「语音 > 朗读音色」（`stella` 海星女声 / `tide` 暗潮男声），存 balance_prefs
  的 `tts_voice_id`，默认 stella；AppStorage 同步供 UI 回显。账户/关于两组按用户要求不做。
- 实测：TTS 接口 200 / `audio/wav` / RIFF 头 / 单句 207KB；引用注入用真实 SSE 复算：
  11 条引用全部命中（0 条落在代码围栏），含代理对文本（码点数 277 vs UTF-16 278）仍位置正确。
- 语音输入（ASR）**已实现**（`042ea20` 服务层、`a79a2df` UI）：点按麦克风开始录音、再点结束，
  转写文本回填输入框；详见下方「语音输入（ASR）」小节。此前"不做语音输入"的决策已作废。

## 联网搜索（DeepSeek 服务端工具，2026-11-19，构建通过）

- 路径选择：官方新开放的独立 Search/Fetch 接口要客户端自己拼检索上下文并按次计费；
  这里改用 Chat Completions 的**服务端工具** `deepseek_web_search`：是否联网由模型判断，
  开深度思考时自动变「深度思考搜索」（一轮多步 search / open_page / find_in_page），
  搜索与抓取都在服务端完成、不计费（只计模型 token）。非 DeepSeek 服务商不展示该开关。
- 请求 `services/ChatService.ets`：`ChatRequestOptions.enableWebSearch` 为真时下发
  `tools: [{type:'deepseek_web_search'}]`。声明后 temperature/top_p/seed/n 等由服务端忽略
  （官方《被忽略的参数》），故温度分支未改；`tool_choice` 不能指向该工具，也不能与其他 tools 混用。
- 解析 `services/WebSearchService.ets`（纯逻辑层，可独立审查）：
  - `parseToolEvent` 读 `choice.server_tool_event`（与 delta 并列，一次 chunk 最多一个）：
    `call_started` 带 action.queries，`call_completed` 带 status/sources。**实测
    call_completed 的 call 不带 kind**，故 kind 缺失一律放行，只丢弃明确的非搜索 kind。
  - `parseAnnotations` 读末块 `delta.annotations`（url_citation，只有 url/title）。
  - `mergeSources` 按 url 去重：先到先得，后到只补空字段，避免搜索结果的 snippet/site_name
    被更短的引用标题覆盖；上限 24 条。
- 展示 `pages/ChatView.ets`：
  - 开关 `WebSearchButton` 与 `ThinkingButton` 并排（胶囊行 96% 宽）；开关值存
    balance_prefs 的 `web_search_enabled`，跨会话/重启保留，只在
    `WebSearchService.isSupported(providerId)`（=deepseek）时渲染。
  - 检索进度复用「思考中...」占位行（`generationHint`），按 action 区分搜索/阅读网页/页内查找；
    `searchState`/`searchHint` 是非持久化字段，完成/出错/停止时清空。
  - 来源卡片 `SourceList` 挂在正文下方，序号即引用序号；点击走系统浏览器（http/https 白名单）。
  - 渲染键 `msgContentPhaseKey` 在正文出现前追加 `S<state><来源数>H<提示长度>`，保证搜索态
    逐帧刷新；正文出现后仍为 `C`，不破坏「MarkdownBody 只挂载一次」的稳定实例约定。
- 持久化 `services/ChatStorageService.ets`：`normalizeSources` 校验 http/https、按 url 去重、
  上限 24；过程态字段不落盘（历史里不会残留「搜索中」）。
- 未做：内联引用角标（annotations 的 start_index/end_index 是 Unicode 码点，需正文插标）见
  `techdebt/TD-002`；旧模型名会话迁移见 `techdebt/TD-005`。
  `deepseek_read_url` 已于 2026-11-23 补齐，见上方「阅读链接与用户元信息」。
- 顺带修正 `services/ModelService.ets` 兜底模型名：deepseek-chat / deepseek-reasoner 已于
  2026-07-24 下线，改为 deepseek-flash / deepseek-v4-pro（实测两者都支持联网工具）。
- 验证：无 mock。用本机 Key 实跑 `deepseek-flash` 普通搜索与深度思考搜索，把真实 SSE 按同一
  规则复算：普通搜索 1 次调用 → 15 条去重来源（含 snippet/site_name），深搜 6 次调用 →
  18 条；`hvigor assembleHap` 构建通过。真机 E2E 被应用锁挡住（系统人脸/指纹不可远程驱动），
  需用户解锁后自行发一条提问确认。

## 工具能力：联网搜索服务商 / 生图 / 内容安全（2026-11-19）

- 设置 > 工具：联网搜索服务商二选一（`deepseek` 内置工具 / `baizhi` OpenAPI），两套百智云 Key
  （`key_baizhi_web` 搜索、`key_baizhi_image` 生图）分开授权；6 个功能开关
  （自动标题 / 文件与图片 / 语音输入 / 朗读 / 图片生成 / 内容安全）存 Preferences 并同步 AppStorage，
  页面用 `@StorageProp` 即时生效。深度思考、智能搜索胶囊位置未变。
- 百智云搜索 `services/BaizhiWebSearchService.ets`：客户端先检索（`POST /openapi/search`），
  把「标题 + 站点 + 摘要 + 链接」拼成系统提示注入，来源挂到 `message.sources`（复用来源胶囊）；
  选 baizhi 时**不再**声明 DeepSeek 服务端工具，避免搜两次；检索失败降级为普通回答。
- 生图 `services/ImageGenService.ets` + ChatService 函数工具：模型判断要画图 → 声明
  `generate_image`（流式 `delta.tool_calls` 按 index 合并）→ 客户端建任务、每 4s 轮询、
  最长 6 分钟 → 结果 URL 挂到消息。旧会话的 `tool_calls` 不落历史（只留图）。
  图片 URL 有时效，持久化后过期会显示空白占位。
- 生图展示：容器按请求比例锁定 `imageAspect`（零布局抖动）、元数据条「百智云 | 比例 | 2K | 耗时」、
  失败原因 + 重试、常驻操作行（预览 / 复制链接 / 浏览器打开）。保存到相册未做（需要媒体写权限）。
- 内容安全：开启后请求带 `safety_check:{level:'high'}`；`finish_reason=content_filter` 或
  `delta.refusal` 触发 `onRefusal`，页面清空已展示文本并给拒答提示（官方要求）。
  审核 token 按输出计费，默认关闭。
## 更新检查（2026-11-19，构建通过）

- `services/UpdateService.ets`：运行时读 `BundleInfo.versionName` 与 release `tag_name` 做逐段数值比较；
  源顺序 **Gitee API → GitHub API**（国内 GitHub 常不可达）；资产优先 `.hap`，其次 `.apk`/首个附件；
  网络失败返回 null、不抛错；静默检查 12 小时节流（`update_prefs.last_check_ts`）。
- 设置页「关于」分组：检查更新（显示当前版本，发现新版弹窗展示 release body + 去下载）、
  开源主页；下载用 `startAbility(viewData)` 交给系统浏览器——HarmonyOS 不允许应用静默安装 HAP。
- 对话页 `aboutToAppear` 静默检查一次，有新版只 toast 提示一次。
- 发布约束（详见 `docs/release.md`）：`versionName` 与 tag 必须同步递增；release 必须挂 `.hap`；
  GitHub 与 Gitee 都要发，否则国内用户会落到 GitHub 兜底而检查失败。
- 签名：`BalanceApp/build-profile.json5` 入库版本**不含 signingConfigs**（本机路径+加密密码），
  开发者本地用 DevEco 生成；本机用 `git update-index --skip-worktree` 保持干净。

## 已移除：上下文净化 Topic Gate / Jev（2026-11-19 删除）

- 原实现（2026-10-20 落地）：写时按句判定切题、把掩码随消息持久化，回放时投影；
  System One 走 Jev（typesafe/openrouter），System Two 复用对话服务商；设置页「对话 > 上下文净化」
  面板配置开关/阈值/渠道 Key。
- 删除原因：用户判断「这个功能有些多余」——判定准确率与收益不匹配维护成本，
  且 Key/渠道/阈值三套配置对普通使用者的理解负担大于收益。
- 删除范围（commit 见 git log「移除上下文净化」）：`TopicGateService.ets`、`JevService.ets`、
  `ChatMessage.topicMask`、`ChatService.applyTopicMask`、`ChatStorageService.normalizeTopicMask`、
  Settings 面板与相关 i18n、SettingsService 的 topic gate / System One Key 接口。
- 兼容性：旧会话 JSON 里的 `topicMask` 字段在读取时被忽略（无对应模型字段），无需迁移；
  旧 Preferences 里的 `topic_gate_*` / `key_jev_*` 键成为无主残留，不影响运行。
- 不要恢复：若要再做上下文压缩，优先考虑「总结式记忆」而不是逐句切题判定。

## 消息列表 LazyForEach 迁移（2026-10-19，已落地，构建通过）

- 问题：`List + ForEach(this.activePath())` 会**一次性实例化整条激活分支**。实测 55 条
  的会话开会话时同时 `new BaseEngine()` × 55 并触发 55 次异步 Markdown 解析：主线程卡顿，
  且可见的尾部消息排在最晚解析 → 内容长时间空白。
- 方案：新增 `services/ChatMessageDataSource.ets`（实现 `IDataSource`），
  消息流改 `LazyForEach(this.msgSource, ...)` + `.cachedCount(2)`，只为视口附近消息建实例。
- 同步策略（关键，避免破坏流式）：
  - `sync(next, nextKeys)` 判定「数量/顺序/消息 id 变化」= 结构性 → `onDataReloaded()`；
  - 否则统计 key 变化面：≥8 条（字号/主题等全表 key 变化）→ 整表 reload；
    1~7 条（思考折叠、流式思考字数 `R<n>`、status 切换）→ 逐条 `onDataChanged(index)` 精确刷新；
  - 正文出现后 key 恒为 `C`，`sync` 不动 → 实例不重建，增量仍由 `MarkdownController` 驱动
    （保持原「同 key 不刷新、靠 controller 喂 token」的机制）。
- 接线：`msgRenderKey(msg)` 同时用于 `LazyForEach` key 与数据源键；`rebuildSessionReference()`
  末尾统一 `syncMessageSource()`；`createNewSession`/`switchSession` 各自补一次 sync。
  索引语义不变（数据源顺序 == `activePath()`），故 `scrollToIndex`/`onScrollIndex` 锚定逻辑无需改。
- 思考折叠：`collapsedReasons` 是普通数组，`msgRenderKey` 只包含该消息自身的折叠标记；
  `toggleReason` 改变标记后必须调用 `syncMessageSource()`，让数据源通知该消息项刷新。
  不使用全局版本号污染所有消息键，否则可能整表重建并破坏 LazyForEach 的缓存同步。
- 结果：开会话只挂载视口内几条消息，卡顿与「空白等渲染」大幅缓解；
  `TD-002` 第 1 项（LazyForEach）落地，`@Reusable` 实例复用仍待做。

## 应用锁与保密会话（2026-10-19，已落地，构建通过）

- 系统认证封装 `services/AuthService.ets`：`authenticate(title)` 走
  `@kit.UserAuthenticationKit` 的 `userAuth.getUserAuthInstance`，认证类型
  **必须同时含 FACE+FINGERPRINT+PIN**，`AuthTrustLevel.ATL2`，challenge 用
  `cryptoFramework` 随机 16 字节；`inProgress` 静态位供生命周期判断，避免认证弹窗
  引起的切后台重复锁定。权限 `ohos.permission.ACCESS_BIOMETRIC`（system_grant/normal）
  已加 `module.json5`。
  - 坑位（真机实测）：系统 UserAuth 组件**不支持「仅人脸+指纹」组合**，
    `CheckAuthWidgetParam: only face+finger not support` → `start()` 直接返错码 8、
    弹窗不出现，调用方只会看到「验证未通过」。故必须带 PIN，系统弹窗仍优先引导
    指纹/人脸，用户可自选。
- 应用锁：设置页「安全 > 应用锁」开关，`SettingsService.setAppLockEnabled` 持久化到
  `balance_prefs` 的 `app_lock_enabled`；`app_locked` 为运行态。`EntryAbility.onWindowStageCreate`
  先 `await SettingsService.init` 再 loadContent（冷启动锁定态在首帧前就绪，避免露内容）；
  `onBackground` 若开关开启且非认证中则置 `app_locked=true`。
  `components/AppLockGate.ets`（挂在 Index 的 Stack 顶层）监听 `app_locked`，锁定态
  全屏 `page_bg` 遮挡并自动拉起认证，成功置 false，失败留在锁屏可重试。
- 保密会话：`ChatSession.isPrivate`（ChatModels/ChatStorageService normalize 缺省 false）。
  历史抽屉长按菜单新增「保密 / 取消保密」；列表项带锁形图标（`ic_lock.svg`），
  ForEach key 追加 `isPrivate` 指纹。点开保密会话走 `openSessionWithPrivacy`
  （系统身份认证）；取消保密也需先认证，防止「不打开会话即可解保再打开」的绕过。
  删除当前会话时优先切首个非保密会话，全为保密则新建空白会话。
- 启动默认新会话 + 草稿会话：`ChatView.aboutToAppear` 不再读取/恢复 `active_session_id`，
  每次重启都进入新会话；但空会话以**草稿**（`draftSession`，不入 `sessions`、不落盘）
  存在，`getCurrentSession()` 优先返回草稿，`attach()` 首次写入消息时
  `promoteDraftIfNeeded()` 才转正并持久化。这样既满足「启动新会话」，又不会在历史里
  堆一堆空「新对话」。启动时顺带清理旧版本遗留的空会话（`messages.length===0`）。
  `createNewSession` 不再 `saveState`（草稿不落盘），`switchSession` 丢弃未使用的草稿。
- 待办：保密标记仅做 UI 门禁，Preferences 内消息仍为明文，见
  `techdebt/TD-003-private-session-plaintext.md`。

## 对话会话体验修正（2026-10-18，已落地，构建通过）

- 输入框（ChatView）：单行 TextInput → 多行 TextArea；折叠态固定两行高（`INPUT_BASE_HEIGHT=68`，
  超出内容由 TextArea 内部滚动），右下角为矢量展开/收起图标按钮（`ic_expand.svg`/`ic_collapse.svg`，
  `inputExpanded` 状态切换 `INPUT_EXPANDED_HEIGHT=200` 查看全文）；发送后自动收起；移除
  `onSubmit`，回车改为换行（不再直接发送）。动态资源名走三元分支两处字面量，符 $r 规范。
- 新会话角色单选：群聊下线后 `togglePendingParticipant` 改单选（再点已选中的角色取消），
  `confirmParticipants` 恒为单聊；选择弹窗重做（顶部拖动条 + 标题/副标题 + 圆形关闭按钮 +
  右侧单选圆圈，去掉冗余“关闭”按钮）；新建角色自动选中。
- 删除会话保留抽屉：`switchSession(sessionId, closeDrawer=true)` 新增开关，`deleteSession`
  删除当前会话时传 false，删完抽屉不收起，可连续长按删除其他会话。

## 群聊 Phase 1（2026-10-05，已落地；已被“群聊下线”取代，仅存档）

- 数据：`ChatMessage.speakerId/mentionedIds`，`ChatSession.participantIds/sceneMode/joinMap`，
  `CharacterCard.knowledge`；存储归一化补缺省并兼容旧数据。
- 建联：新会话角色卡多选 + 开始对话确认；单选绑定单聊（含开场白），多选自动群聊（空白开场）。
- 路由：`sendGroup` 确定性路由（@ 优先 → 规则回退上轮发言人/首位成员 → 全体沉默插提示）；
  按序链式生成（后者挂前者之下），出错即停；`generateReply` 改为 Promise 以支持等待链。
- 显示：助手气泡头显发言人名，用户气泡显 @ 对象；@ 按钮仅群聊展示，成员小弹窗多选
  （居中轻量卡片，✓ 即切），chips 回显，发送时选择器＋文本扫描（CJK 边界）双通道校对落库。
- 私有知识拼入对应发言角色的 systemPrompt（标注不得外泄）。

## 已移除：用户身份卡（2026-11-20 删除）

> 原设计（2026-10-05 落地）已整体下线，以下为删除记录，留档避免重复设计。

- 删除范围：`UserIdentityCard` 实体与 `saved_identities` 存储、`ChatSession.userIdentityId`、
  ChatView 的身份状态/编辑弹窗/删除确认/「我的身份」分组/「我扮演（可选）」单选、
  系统提示词里的「用户剧中身份」段、请求历史的「身份名：」前缀、用户气泡右上身份名。
- 兼容：历史会话 JSON 里残留的 `userIdentityId` 字段在 normalize 时被忽略；
  本地 `saved_identities` 键不再读写（未被读取，不会再出现在 UI 上）。
- 角色卡（`CharacterCard`）、保密会话、@ 发言人等相邻能力不受影响。
- 历史实现要点（已无用，仅供追溯）：独立存储 `saved_identities`；角色管理内「我的身份」分组
  新建/编辑/长按删除；新会话建联时单选并锁定；system prompt 追加身份段、历史用户发言前缀身份名。

## 对话与资产体验第二批（2026-10-05，已落地）

- 删除二次确认：新增可复用 `components/ConfirmDialog.ets`（show/title/message/confirmText/danger +
  onConfirm/onCancel；函数类型不可 @Prop，用普通成员）；会话删除与角色卡删除统一接入。
- 移除右上角「清空对话」按钮及 `clearSessionMessages`。
- 角色管理：历史抽屉底部加「角色管理」入口；角色卡面板分 select（新会话多选建联，无新建按钮）
  /manage（新建+点行编辑+长按菜单）两态；`characterSheetMode` 控制。
- 深度思考开关移至输入框下方左侧（仅支持厂商展示）。
- 资产页：~~Jev 智能路由配置卡~~（2026-11-19 随上下文净化一并移除，代码中已无 `key_jev`/`jev_enabled`）；
  添加服务商弹窗加「未添加/已添加」分段过滤。

# BalanceApp systemmap（初始）

## 入口点

- `BalanceApp/entry/src/main/ets/pages/Index.ets` — Dashboard 总览（总资产 Hero + 服务商卡片 + 添加弹窗 + 空态），对齐智额 dashboard_screen/HeroStatsCard/PremiumProviderCard 前端形式。
- `BalanceApp/entry/src/main/ets/services/ProviderRegistry.ets` — 数据驱动注册表。
- `BalanceApp/entry/src/main/ets/services/BalanceService.ets` — 通用查询引擎 + 错误通道。

## 核心数据模型

- `BalanceInfo { providerId/total/used/available/currency/updatedAt }`（ProviderRegistry.ets，对齐智额 balance_info.dart）
- `ProviderDefinition { id/name/baseUrl/category/balanceType/balanceConfig/brandColor }` + `PROVIDERS[3]`（ProviderRegistry.ets，对齐智额 registry，酒馆除外；2026-10-04 新增 Kimi（月之暗面）api.moonshot.cn/v1/users/me/balance，成功语义 code==0；2026-11-20 精简为 DeepSeek / Kimi / 小米 MiMo 三家，阶跃 StepFun、OpenRouter、Novita AI 连同图标一并移除，`ProviderCategory` 仅保留「国内官方」）
- 通用 bearer 引擎：responsePath 导航 + 数组求和 + 换算因子 + used 推导（BalanceService.ets，对齐智额 BearerBalanceAdapter；OpenRouter available 对称推导为本侧修正）
- 本地持久化：Preferences `balance_prefs` 存 `addedIds` + `key_<id>`（Index.ets）
- UI 状态：`records: ProviderRecord[]` + `refreshView()` 重建数组推刷新 + ForEach 数据指纹 key 防复用旧快照（Index.ets，ArkTS @State 深层观察不到的补偿）
- 品牌图标：`resources/base/media/` 下 deepseek/kimi/mimo（2026-11-20 删除 stepfun/openrouter/novita 三张已下线厂商图）
  已于 2026-10-23 统一替换为官方品牌资源（256×256 透明 PNG，来源为各官网 SVG/应用图标，
  见 `mobile/README.md` 的 Provider icons）；`ProviderDefinition.icon` + `Index.providerIcon`
  静态 $r 映射（$r 不支持动态拼接）

## 本次任务所涉现状

- 空目录脚手架 → `devecocli create BalanceApp (API 24, com.example.openchat)`，debug 构建成功。
- 真机 `6UNBB26820047956`（UDID `5FB0F2328…BD1E4`）已在 AGC 登记，`devecocli signature generate`
  自动签名成功，`devecocli run` 签名构建+安装成功，`aa start` 启动成功，真机截屏确认
  查询页正常渲染（供应商选择/BaseURL/Key输入/查询-清空按钮/底部说明）。
- 产物：签名 HAP 位于 `entry/build/default/outputs/default/`（-signed）。
- 2026-10-04 dashboard 对齐验证：DeepSeek 真 Key 查询 258ms 回 200，Hero ¥4.89 与卡片
  ¥4.8900/总额/已用/进度条一致；修复过 ForEach 复用旧快照致卡片常显查询中
  （数据指纹 key + refreshView 重建数组，详见 Index.ets cardVersionKey/refreshView）。

## 对话与导航架构（2026-10-05 改造）

- 页面结构（main_pages.json）：`pages/Index`（壳，仅渲染 ChatView）→ `pages/Settings`
  （设置）→ `pages/Assets`（资产监控，由原 Index dashboard 迁出）。底部 Tabs 已移除，
  应用主界面即对话。
- 设置页 Settings.ets：仅入口占位——语言 / 外观 / 字体大小 / 个性化（点击 toast
  「该功能暂未实现」）+ 「资产监控」入口（router.pushUrl → pages/Assets）。
- 对话导航：ChatView 顶部左侧三横杠打开历史抽屉；抽屉底部「设置」行 → Settings。
- 思考模式（ChatService.ets）：`ProviderDefinition.supportsThinking`（deepseek/kimi/mimo=true）
  控制是否下发 `thinking:{type:enabled/disabled}` 与 `reasoning_effort`；Kimi K3 始终推理
  只下发 `reasoning_effort`（默认 max），K2.7 始终思考不下发任何开关，思考开启时按官方
  规范不下发 `temperature`；非支持厂商不传非标准字段。保留式思考：Kimi/MiMo 历史回传
  `reasoning_content` 保多轮思维连贯（DeepSeek 无 tools 场景传了也被忽略，统一回传无害）。
- 流式/记忆（ChatService.ets，对齐 Kimi 官方两节规范）：SSE 以 `data:[DONE]` 为唯一完成判据
  （不用 finish_reason；中断走 err 回调）；`delta.content/reasoning_content` 追加折叠，
  终块 `{choices:[],usage}` 直接跳过（token 统计已下线，不下发 `stream_options.include_usage`）；
  `tool_calls` 无 tools 声明有意忽略，`n` 恒为 1 不下发。记忆为无状态回传：
  `buildApiMessages` 收口流式/非流式，system 常驻首位，历史取新截断（最新 20 条 +
  12000 字符双预算，超限从旧丢弃）；全量历史仍按 session 存 Preferences，只裁剪本次请求。
- Markdown 渲染（FluidMarkdown `fluid-markdown@1.0.11`，ohpm，`MarkdownService/MarkdownBody`）：
  自研引擎已否决，复用支付宝开源库（Apache-2.0，原生 StyledString，无 WebView）。
  流式走 Typing 模式（累计文本 + Begin/Append/End，库内 hash 差量 + 打字机 pacing），
   完成/历史走 Normal；`MarkdownController` 按消息单例存活（建于生成开始、终于完成/停止/
   删会话），ForEach key 去掉 content 长度保实例稳定。库契约：`typing.update`
   只能在 `onMarkdownTypingReady` 之后（`MarkdownBody.onTypingReady` 回调记
   `mdTypingReady`，就绪前跳过不记 begun；完成前未 Begin 则不发 End）。
   高频刷新节流 `refreshStreamView`（~8fps）：driveMarkdown + 整表重建 + 思考跟随
   统一压到 tick，喂库永远累计文本故合并无损（直驱百 Hz 重建会压垮 UI 线程，
   视感"一次性"）。`[ref_N]` 改写为 `[N](#cite-N)`
  （围栏/行内代码内不碰），点击路由：引用 toast（来源列表待模型侧，见 TD-002）、
  外链仅 http/https/mailto 走 viewData 拉起。主题映射字号（`app_font_scale`，`@Prop` 接
  `@StorageProp`）与深色正文色；代码高亮/复制为库内置（highlight.js 移植，无需 prism4cj，
  其为 Android 侧）；表格列宽自适应故无外层横滚。延迟项见 `techdebt/TD-002-markdown-followups.md`
  （LazyForEach 迁移/来源面板/Worker 实测/LaTeX 缺失）。
- 数据模型：CharacterCard 移除 `tags`；ChatMessage 移除 `usage`，ChatUsage 接口删除
  （token 统计功能整体下线）。角色卡不再内置预设，DEFAULT_CHARACTERS=[]，无角色时用
  EMPTY_CHARACTER 兜底。

## 全局视觉主题（2026-10-20）

- 视觉方向为「温润静奢」：浅色采用暖纸白、墨色与克制的香槟金，深色采用温润墨黑与柔金；
  两套资源在 `resources/base/element/color.json` 与 `resources/dark/element/color.json` 使用同名语义 token。
- `accent` 用于文本强调，`accent_solid` / `accent_contrast` 负责主操作表面与对比文字，
  `accent_soft` / `accent_soft_selected` 负责选中态，`hero_*` 固定深墨资产总览层级，
  `overlay_scrim` 统一用于抽屉和弹层遮罩。Markdown 正文主题由 `MarkdownService.applyTheme()` 显式映射。
- 主聊天入口与历史抽屉、模型/角色/消息弹层、设置、资产监控、确认对话框及应用锁共用该色板；
  首页空态、消息气泡、输入区、资产 Hero 与设置卡片依颜色 token 建立统一层级。设置图标使用暖色底片，
  对应 SVG 线色已调整为可读的深金色。
- 本次只改变呈现和布局，不改变聊天发送、模型选择、会话持久化、资产查询、认证及设置保存流程。

## 消息分支、交互细化与锚定滚动（2026-10-05 第二批）

- 消息分支（ChatModels/ChatStorageService/ChatView）：`ChatMessage` 增加
  `parentId/childIds/activeChildId`，`ChatSession` 增加 `rootIds/activeRootId`；消息池为扁平
  节点树。`ChatStorageService.normalizeSessions` 在持久化边界做 Schema 校验并把旧线性
  数据迁移为单链树 + 修复悬空引用。渲染只走 `activePath()`（沿 activeChildId）。
  长按消息 → 编辑并重发（user，同父新增兄弟节点）/ 重新生成（assistant）；气泡右下角
  `< i/n >` 切分支；请求历史用 `historyTo()` 取该分支根到目标的路径。
- 默认会话空白、不绑定角色；点「+ 新会话」先建空白会话再弹角色选择（selectCharacter 补开场白）。
  顶部「厂商」行移除。
- 角色卡：`DEFAULT_CHARACTERS=[]`；列表项去掉“编辑”按钮，改长按弹操作菜单（编辑/删除）；
  编辑弹窗去掉「角色简述」与 `(System Prompt)` 文案。
- 选择服务商与模型：只列出本地已配置 `key_<id>` 的服务商（`loadConfiguredProviders()`）。
- 设置页：语言/外观/字体大小/个性化/资产监控图标改为 `resources/base/media/ic_*.svg`
  （工程化图标，非文字占位）；历史抽屉「设置」行去掉副标题、加齿轮图标。
- 软键盘避让（Index.aboutToAppear）：`getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)`。
  默认 OFFSET 会整页上移致顶栏被顶出屏幕，RESIZE 压缩内容区、顶部固定、聊天区收缩。
  获焦追加：输入框 `onFocus` 在非生成态下分两次（120/380ms）`scrollEdge(Bottom)`，
  保证最新消息不被键盘/收缩区遮挡。
- 会话管理：历史抽屉去掉删除按钮，长按弹菜单（重命名/删除），删除需二次确认弹窗。
- 角色绑定：移除顶部角色切换入口；角色只能在「新会话」弹窗中选择一次，选中后锁定
  （`selectCharacter` 遇已绑定直接 toast 拒绝）；`createNewSession` 重置 `currentCharacterId`。
- 思考过程：方框去掉固定宽度由父气泡包裹；标题行点击「展开/收起」折叠
 （`collapsedReasons + reasonVersion` 强制 ForEach 按 key 刷新）。
- 过渡动画：底部面板统一 `translate(y:360)+ExtremeDeceleration/320ms`，蒙层 `opacity/280ms`，
  历史抽屉面板加左侧滑入。
- 流式顶部锚定滚动（ChatView，Auto Scroll Top Anchor，一次性锚定 2026-10-05 修复）：
  单条回复只在首 token 到达时调一次 `scroller.scrollToIndex(idx, false, ScrollAlign.START)`
  （`anchoredForMsgId` 落标记），顶部固定后内容向下生长视口自然不动；非生成态
  （历史浏览/图片后加载）、用户已接管、已锚定一律直接返回，杜绝每 token 重推把拖动拽回
  （此前每 token + 每次 Markdown 尺寸变化都重锚定，长回答体感“拉不动”）。
  接管检测双通道：`onScrollIndex` 管条目间（end < total-1）；超长单条气泡内部拖动
  end 恒为末条，靠 `onScrollStop` 比较 `currentOffset` 与 `lastAnchorOffset`
 （差值 >30px 即接管并显示「回到底部」）；`onReachEnd` 或点按钮恢复。
  思考区/内容区高度变化只做 offset 记账，不再 bump `reasonVersion`
 （否则 ForEach key 全变致整表重建、滚动跳变）。
  同理：思考结束自动折叠与生成完成时也不 bump `reasonVersion`
 （2026-10-05 跳顶/回复"消失"修复）—— ForEach key 已含 `status` 与折叠态，
  当事条目照常重建（完成时切 Normal 全量渲染）；bump 会改全表 key 致 List
  滚动归零到顶部、新回复沉底不可见。`toggleReason` 的 bump 必须保留
 （`collapsedReasons` 非 @State，那里靠它本身触发渲染）。
- 思考区流式体验（ChatView + MarkdownService，2026-10-05）：思考区定高 380 + 内嵌
  Scroll，流式超出后新文本沉底不可见 → 按消息 id 懒建 `thinkScrollers` 跟底，
  仅内滚动已在底部时跟随（用户上翻查看旧思考不动）；每轮生成重置
  `reasonChunkCount/contentChunkCount`，完成时打一行 hilog 区分"服务端一次性下发"
  与"UI 未刷新"。图片居中限高曾走 `theme.image` 下发，导致整块 Markdown 空白
 （已回退：疑普通对象不符合库内样式级联预期，渲染期异常；居中方案待定）。
  思考标题栏整行可点
  （width 100% + 上下 10vp padding，箭头另加 12/8 padding）；分支切换 `‹ ›`
  内边距加到 16/10。

## 缺陷修复（2026-10-05，已落地，构建通过）

- 流式不刷新根因（ChatView）：ForEach 同 key 复用旧快照，原 key 不含流式进度 →
  正文首 token 不触发 MarkdownBody 挂载、思考 Text 流式期静止。修法：key 增加
  `msgContentPhaseKey`——正文未出现前为 `R<思考字数>`（逐帧重建让思考文本刷新，
  此时 MarkdownBody 未挂载无副作用），正文出现后固定 `C`（MarkdownBody 仅挂载一次，
  增量由 controller 驱动不重建）。思考内滚动 `followThinking` 改为生成期间统一定底
  （条目重建会重置内滚动，`isAtEnd` 会误判）。`onTypingReady`/`mdTypingReady` 机制
  至此才真正生效。
- 深色模式（全仓）：新增 `resources/base|dark/element/color.json` 语义色板
  （page_bg/surface/text_*/divider/accent_soft/reasoning_*/user_bubble_text/hero_bg/
  danger_text 等），ChatView/Settings/Assets/ConfirmDialog/ThinkingButton 的硬编码
  色值改用 `$r('app.color.*')`，由 `setColorMode` 自动切；白色仍保留仅用于彩底按钮
  前景。解析深色态 `app_dark`（system 跟随系统）由 `SettingsService.resolveDark`
  （读 `context.config.colorMode`）落 AppStorage，`EntryAbility.onConfigurationUpdate`
  在 system 模式跟随系统变化；ChatView `isDarkMode()` 读 `app_dark`，Markdown 主题
  随之切换，修复"深色下正文浅字白底隐形"。
- 资产页整轮刷新失效（Assets）：单卡 `refreshOne` 自增 `globalSession` 作废进行中的
  `refreshAll`，但 `refreshAll` 收尾条件不成立 → `refreshingAll` 卡 true、按钮永久
  置灰；修法：`refreshOne` 内复位 `refreshingAll=false`。
- 删除当前会话状态不同步（ChatView）：`deleteSession` 删当前会话后委托
  `switchSession(sessions[0].id)`，重同步 provider/model/key 并重载模型（原逻辑只改
  会话/角色，头部与发送会用错厂商）。
- 待办（本次未动，已识别）：多语言仅 Settings 覆盖、字号仅 ChatView 生效、模型选择
  无手动输入、移除服务商无二次确认、MiMo 余额端点 `/v1/models` 恒 0 等，见审查清单。

