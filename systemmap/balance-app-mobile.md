---
covered_paths:
  - mobile/lib/main.dart
  - mobile/lib/app.dart
  - mobile/lib/core/app_version.dart
  - mobile/lib/core/i18n/settings_strings.dart
  - mobile/lib/core/theme/app_colors.dart
  - mobile/lib/core/theme/app_theme.dart
  - mobile/lib/core/utils/markdown_utils.dart
  - mobile/lib/data/models/chat_models.dart
  - mobile/lib/data/models/provider.dart
  - mobile/lib/data/services/asr_service.dart
  - mobile/lib/data/services/auth_service.dart
  - mobile/lib/data/services/baizhi_web_search_service.dart
  - mobile/lib/data/services/balance_service.dart
  - mobile/lib/data/services/chat_service.dart
  - mobile/lib/data/services/chat_storage_service.dart
  - mobile/lib/data/services/file_upload_service.dart
  - mobile/lib/data/services/image_gen_service.dart
  - mobile/lib/data/services/key_store.dart
  - mobile/lib/data/services/model_service.dart
  - mobile/lib/data/services/preferences_service.dart
  - mobile/lib/data/services/tts_service.dart
  - mobile/lib/data/services/update_service.dart
  - mobile/lib/state/assets_controller.dart
  - mobile/lib/state/chat_controller.dart
  - mobile/lib/state/settings_controller.dart
  - mobile/lib/ui/app_lock_gate.dart
  - mobile/lib/ui/pages/assets_page.dart
  - mobile/lib/ui/pages/chat_page.dart
  - mobile/lib/ui/pages/chat_sheets.dart
  - mobile/lib/ui/pages/settings_page.dart
  - mobile/lib/ui/widgets/confirm_dialog.dart
  - mobile/lib/ui/widgets/message_bubble.dart
  - mobile/lib/ui/widgets/provider_logo.dart
  - mobile/lib/ui/widgets/thinking_button.dart
  - mobile/lib/ui/widgets/web_search_button.dart
  - mobile/android/app/build.gradle.kts
  - mobile/android/app/src/main/AndroidManifest.xml
  - mobile/android/app/src/main/kotlin/com/example/openchat/MainActivity.kt
  - mobile/ios/Runner/Info.plist
  - mobile/ios/Runner.xcodeproj/project.pbxproj
  - mobile/pubspec.yaml
  - mobile/test/balance_service_test.dart
  - mobile/test/citation_test.dart
  - mobile/test/ui_smoke_test.dart
last_verified_commit: 67a08c8
last_verified: 2026-11-23
---

# BalanceApp Mobile（Flutter Android/iOS）systemmap

> 与鸿蒙端 `systemmap/balance-app.md` 并列：同一产品、不同代码库、互不共享本地数据。
> 本文件只描述 `mobile/` 的 Flutter 实现；鸿蒙端的协议细节仍以原 systemmap 为准。

## 定位与范围

- 单代码库覆盖 Android 与 iOS；iOS 目标已配置但未在 macOS 编译（见 `TD-004`）。
- 功能对齐鸿蒙端：资产监控、流式对话、会话分支、角色/身份卡、保密会话、应用锁、
  Jev 上下文净化、外观/字号/设置页多语言。
- 明确不做：群聊（鸿蒙端已下线）、文件/图片上传、token 用量统计。

## 启动与生命周期

- `main.dart`：`WidgetsFlutterBinding.ensureInitialized()` → `PreferencesService.load()`
  → `SettingsController.load()` → 构造 `ChatStorageService/AssetsController/ChatController`
  → `runApp(BalanceApp)`。构造顺序固定，控制器之间不互相持有。
- `app.dart`：`MultiProvider` 注入三个 `ChangeNotifier`；
  `MaterialApp.builder` 用 `MediaQuery.textScaler = fontScale` 统一字号，并用
  `AppLockGate` 包住整个 Navigator，使锁屏覆盖所有路由。
- `StartupGate`：首帧前 `await chat.init()`；模型列表刷新在 `init` 内部 fire-and-forget，
  不阻塞启动。
- `AppLockGate`：`WidgetsBindingObserver` 在 `paused` 时调用 `settings.lock()`，
  `resumed` 且仍锁定时自动拉起认证；`AuthService.isInProgress` 防止认证弹窗
  导致的二次锁定。锁屏成功 `settings.unlock()`。

## 数据模型与持久化边界

- `ProviderDefinition`：纯数据注册表；除余额配置外新增 `chatEndpoint` 与
  `modelsEndpoint`（OpenRouter `/api/v1/*`、Novita `/openai/v1/*`、DeepSeek `/chat/completions`），
  不再假设所有厂商都在 `/v1` 下。
- `BalanceInfo`：总额/已用/可用/币种/更新时间；百分比由 `usagePercentage` 派生。
- `ChatMessage`：扁平节点树字段 `parentId/childIds/activeChildId`；`topicMask` 随消息持久化。
- `ChatSession`：`rootIds/activeRootId`、`isPrivate`、`participantIds/sceneMode/joinMap`
  （群聊字段保留以兼容鸿蒙结构，运行时恒为单聊）。
- `ChatStorageService`：SharedPreferences JSON；所有读入都走 `tryParse`/`_normalizeSession`，
  非法记录丢弃；旧线性数组迁移为单链树并修复悬空引用。
- `PreferencesService`：非敏感偏好（外观/字号/语言/应用锁开关/topic gate 配置/
  已添加厂商 id/活动会话 id）。
- `KeyStore`：`flutter_secure_storage`，按 `key_<providerId>` 与
  `key_jev_typesafe` / `key_jev_openrouter` 存储；写入前 trim，空值删除。

## 网络协议

### 余额查询 `BalanceService`

- `fetchProviderBalance(id, key)`：空 key / 未知厂商在边界直接返回 `success:false`；
  401/403、非 2xx、JSON 结构非法、业务码不符均返回确定性失败；网络异常向上抛，
  由 `AssetsController` keep-last-good 并提供重试。
- `parseBalanceBody` 为纯函数（`@visibleForTesting`）：responsePath 点分导航、
  数组求和、字段映射、`amountMultiplier`、used/available 对称推导。
- 端点为 `baseUrl + endpoint`；绝对 URL 直用。

### 对话 `ChatService`

- 端点：`def.baseUrl + def.chatEndpoint`。
- SSE：只认 `data:[DONE]` 完成；忽略 `finish_reason`；`choices` 为空的 usage 终块跳过；
  `delta.content`/`delta.reasoning_content` 追加。
- 历史：`buildApiMessages` 先 system，再取新 20 条 + 12000 字符双预算；
  assistant 历史按 `topicMask` 投影，掩码长度不符 fail-open；保留式思考回传
  `reasoning_content`。
- 请求体按厂商分支：Kimi K3 传 `reasoning_effort`；K2.7 不传 thinking/temperature；
  K2.6 传 `thinking.type`；MiMo 传 `thinking.type`；其余支持思考的厂商传
  `thinking.type + reasoning_effort`，关闭时传 `temperature`。
- 中断：`ChatController.stopGenerating` 自增 generation token 并取消订阅；
  迟到的 done/error 回调因 token 不符被丢弃。

### 模型列表 `ModelService`

- 先请求 `baseUrl + modelsEndpoint`，再兜底 `/models`、`/v1/models`；全部失败时使用
  厂商内置兜底（DeepSeek/Kimi/MiMo），其余返回空。
- 仅列出已配置 Key 的厂商：`ChatController.loadConfiguredProviders` 逐个读安全存储。

### Jev 上下文净化（鸿蒙端已移除，移动端待同步）

> 2026-11-19：鸿蒙端已整体删除上下文净化（`TopicGateService`/`JevService`/设置面板），
> 判断为「多余功能」；移动端 Flutter 侧暂保留，后续做功能对齐时应一并移除，避免两端能力分叉。

- `JevService`：固定两个渠道与模型（`typesafe` / `openrouter`），一次请求合并所有分段，
  Noul 问句返回 `answers.segment_i.noul`。
- `TopicGateService`：按 `。！？!?；;` 与换行无损切段；`applyTopicMask` 长度不符或
  全保留时返回原文；`annotate` 在回复落库后异步执行，任何失败返回 false（fail-open）。
- 判定主题取产生该回复的用户消息，不是当前会话主题。

## 状态控制器

- `SettingsController`：外观（system/light/dark）、7 档字号、自动折叠思考、语言、
  应用锁开关与运行态、topic gate 开关/阈值/渠道；所有写操作先 notify 再持久化。
  持有 KeyStore 读写方法，供设置页与聊天页共用。
- `AssetsController`：厂商记录（key/info/error/loading/updatedAt）、`_session` token、
  `refreshingAll`；`refreshOne` 会复位 `refreshingAll`，避免整轮刷新卡死；
  `reloadKeys` 供 System Two 设置改 Key 后同步。
- `ChatController`：会话池 + 草稿、激活分支、角色/身份、模型选择、流式生成。
  - 草稿：启动即新草稿，不落盘；`attach` 首次写消息时 `_promoteDraftIfNeeded` 转正。
  - 分支：`activePath` 沿 `activeRootId/activeChildId`；编辑/重发生成兄弟节点；
    `switchBranch` 只改父指针。
  - 流式刷新：120ms ticker 合并 notify；完成/失败立即 notify。
  - 隐私：打开保密会话需认证；取消保密也需认证（防绕过）。
  - 删除当前会话优先切首个非保密会话，否则新建草稿。
  - 用户名注入：请求历史的 user 消息加 `身份名：` 前缀（拷贝，不改存储）。

## UI 结构

- `ChatPage`：自定义顶栏（抽屉/标题/模型胶囊）、消息 `ListView.builder`、
  输入区（多行 TextField + 展开/收起 + 发送/停止 + 深度思考开关）、
  回到底部浮钮、历史抽屉（搜索会话/新建/长按操作/角色管理/设置）。
- `MessageBubble`：用户气泡右侧；助手 Markdown + 思考折叠块 + 错误行 + 分支计数；
  长按复制/编辑/重新生成；链接安全路由（http/https/mailto）与引用 toast。
- `chat_sheets.dart`：模型/厂商选择、会话操作、消息操作、角色与身份管理/绑定。
- `AssetsPage`：Hero 分币种汇总、厂商卡片、添加弹窗（未添加/已添加 + 搜索）、
  Key 弹窗、长按操作（刷新/换 Key/移除并二次确认）。
- `SettingsPage`：应用（语言/外观/字号）、个性化、安全（应用锁）、数据（资产监控）、
  对话（上下文净化入口）、版本。
- `TopicGatePage`：开关、System One/System Two 双 tab、渠道/Key/阈值、
  服务商 Key（与资产监控共用）。
- 主题：`AppColors` 语义 token（暖纸/墨/香槟金）与 `AppTheme`；所有页面只读 token。
- 厂商图标：`assets/providers/*.png` 为 2026-10-23 从各官网 SVG/应用图标重新抓取的
  256×256 透明品牌标记（DeepSeek 鲸、Kimi K+蓝点、OpenRouter R、SiliconFlow 紫色标记、
  StepFun 像素徽标、Novita 几何标记、MiMo 官方 MIMO 字标）；不热链、不依赖运行时网络。

## 平台配置

- Android：applicationId/namespace `com.example.balanceapp`；`minSdk = maxOf(flutter, 24)`；
  `MainActivity : FlutterFragmentActivity`；manifest 含 `INTERNET`，label `BalanceApp`。
- iOS：bundle id `com.example.balanceapp`；部署目标 13.0；
  `NSFaceIDUsageDescription` 已配置；无 Podfile（需 macOS 首次 `pod install`）。
- 构建网络：本机直连 `storage.googleapis.com` 会 TLS 握手失败，必须设置
  `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`。

## 验证状态（2026-10-23）

- `flutter analyze`：0 issue。
- `flutter test`：23 项通过（余额解析/边界、切段/掩码、引用改写、厂商端点、页面冒烟、应用锁浮层、Markdown 气泡）。
- `flutter build apk --debug`：成功（镜像环境）。
- 运行时：未完成。本机 AVD 的 `system.img` 缺失，且无 Android 真机；iOS 无 macOS。
  详见 `techdebt/TD-004-mobile-release-readiness.md`。

## 已知边界

- 会话正文明文存储在 SharedPreferences；`isPrivate` 只是 UI 门禁（同鸿蒙 TD-003）。
- 多语言只覆盖设置页（同鸿蒙现状）。
- 没有 release 签名、商店图标、隐私政策；应用锁关闭无需二次认证。
- Markdown 由 `gpt_markdown` 渲染，代码高亮/复制为库能力；引用来源列表仍待模型侧提供。
- 联网搜索（DeepSeek `deepseek_web_search` 服务端工具）、正文引用角标/来源胶囊、语音朗读
  （`/v1/tools/tts` + 朗读音色设置）均尚未对齐：鸿蒙端已在 2026-11-19 接入（`4f5fbd6`、`595db48`），
  移动端仍是旧协议，差异与移植要点见 `techdebt/TD-006`。

## 2026-11-20 追平记录（与鸿蒙端对齐）

一次性补齐了 Android/iOS 端此前缺失的能力，关键实现位置：

- **应用身份**：`com.example.openchat`（Android namespace/applicationId + MainActivity 包路径，
  iOS bundle id 含 RunnerTests），版本 1.0.1+2；
- **检查更新**：`data/services/update_service.dart`（Gitee 优先、GitHub 兜底，语义化版本比较，
  资产优先 .hap/.apk），设置页「关于」分组；
- **工具设置**：设置页「工具」分组 —— 联网搜索服务商（DeepSeek/百智云）、两套百智云 Key
  （KeyStore：`key_baizhi_web` / `key_baizhi_image`）、6 个功能开关（Preferences 前缀
  `feature_*` + `web_search_provider` + `tts_voice`）；
- **联网搜索**：`chat_service` 声明 `deepseek_web_search`，解析 `server_tool_event` 与
  `delta.annotations`（码点偏移）；`baizhi_web_search_service` 客户端检索后注入系统提示；
  正文角标 `[N](#cite-N)` + 来源胶囊（编号与角标一致）；
- **文件/图片**：`file_upload_service`（Files API，purpose 按扩展名选择，图片走 user_data 保证
  视觉可用），消息 content 数组 file 块在前、文本在后；输入区「＋」三入口；
- **语音**：`asr_service`（16k 单声道 WAV → `/v1/tools/asr`）、`tts_service`
  （`/v1/tools/tts` + 临时目录缓存 + audioplayers 播放），朗读音色可选；
- **生图**：`image_gen_service`（百智云异步任务 + 4s 轮询），`generate_image` 函数工具，
  流式 `tool_calls` 按 index 合并，消息持久化 imageState/imageUrls/imageMeta/imageAspect；
- **内容安全**：`enableSafety` → `safety_check: {level: high}`，拒答清空内容并提示；
- **删除**：TopicGate/Jev 全链路（服务、页面、消息字段、开关、Key 常量、单测）。

验证：`flutter analyze` 零 issue，`flutter test` 18 项通过；无模拟器/真机，录音、相册、
文件选择、音频播放与生图仍需真机验证。

## 历史侧栏对齐官方（2026-11-20）

- 抽屉头部由「历史会话」标题行改为搜索框 + 「+ 新会话」，与鸿蒙端同版式；
  会话行改扁平行（只有选中项用 `accentSoftSelected` 浮起，不再每行描边卡片）。
- `_SessionDrawer` 由 StatelessWidget 改 StatefulWidget：`TextEditingController`
  持有关键词，`_filteredSessions()` 按标题过滤（大小写不敏感），空结果显示
  「没有匹配的会话」。Flutter 端 Drawer 全程挂载，故无需像鸿蒙端那样每次打开清空关键词。
- 冒烟测试 `ui_smoke_test.dart` 同步：抽屉断言从「历史会话」改为搜索占位与新会话按钮。

## 主题体系与鸿蒙端对齐（2026-11-20）

- `lib/core/theme/app_skins.dart` 是**生成文件**：`scripts/gen_flutter_skins.py` 从鸿蒙端
  `services/SkinService.ets` 解析 4 套皮肤 × light/dark 的 50 个 token，映射到 `AppColors` 的 34 个字段。
  改配色只改鸿蒙端再跑脚本，禁止手改生成结果（两端同值才不会慢慢漂移）。
- `AppTheme.of(colors, brightness)` 接受任意调色板；`MaterialApp` 的 theme/darkTheme 取
  `settings.skin.light` / `.dark`，因此「明暗」跟着系统走时也是当前皮肤自己的深色。
- 默认皮肤 `official`（官方蓝白），与鸿蒙端一致；`paper`（暖纸）保留为可选风格。
- 偏好键 `skin_id`（`PreferencesService.keySkin`），`SettingsController.setSkin` 先 notifyListeners 再落盘。

## 四项能力补齐（2026-11-23，analyze/test 通过）

1. **会话标题接服务端**：此前只解析 `delta.title` 却从不声明 `title`，设置里的「自动生成会话标题」
   形同虚设。现 `ChatRequestOptions.enableTitle` → `title:{enabled:true}`，`ChatSession.autoTitled`
   保证每个会话只请求一次；服务端标题只在「标题仍是自动取名」时覆盖（`_isAutoTitle` 比对默认名
   与首条用户消息截断），用户重命名过的保留。
2. **兜底模型名**：`model_service.dart` 从已下线的 `deepseek-chat/deepseek-reasoner` 改为
   `deepseek-flash/deepseek-v4-pro`（与鸿蒙端、TD-005 对齐）。
3. **阅读链接 `deepseek_read_url`**：声明工具、解析 `server_tool_event` 的 `read_link`（进度文案、
   `call.page` → 来源卡片），并把末块 `delta.server_tool_calls` 原文存进
   `ChatMessage.serverToolCallsJson`，`buildApiMessages` 原样回传（含 signature）。
   设置>工具新增「阅读链接」（`feature_read_url`，默认开）。原文按 200KB/条封顶。
   **顺带修复**：`server_tool_event` 原先按不存在的 `phase` 字段解析，检索进度从未显示过。
4. **用户元信息 `latest_reminder`**：每条 user 消息前插
   `<date>,<weekday>,<location>,App,<language>`，日期取消息自身时间，语言跟随界面（中文/English），
   仅 DeepSeek 注入；设置>工具新增「所在地」（`user_location`，可留空）。截断按「历史单位」做，
   reminder 与所属 user 消息不会被拆开。

另修复：`generateReply` 的历史投影丢 `attachments`，导致多轮追问文档时第二轮就失忆
（`replayMessage` 统一带全可回放字段）。

已知边界：`flutter analyze` 零 issue、`flutter test` 30 项通过；本机无真机/模拟器，
阅读链接、reminder 的真实接口表现仍需真机回归（`techdebt/TD-007`、`TD-004`）。

## 对话页对齐官方 chat-demo（2026-11-23，analyze/test 通过）

参考 <https://github.com/deepseek-ai/chat-demo>（React 端侧 demo）重做四处移动端体验，
原则是「借语义不搬实现」：demo 的 hover 预览、可拖拽分栏、桌面侧栏在手机上不成立。

1. **搜索结果**：正文下方由「N 个来源胶囊」改为「最多 4 个重叠站点图标 + 参考了 N 个网页 +
   箭头」摘要行（`ui/widgets/search_sources.dart`），点开底部面板看完整来源卡片（序号、
   站点图标/名称、日期、标题两行、摘要两行），点卡片开系统浏览器。`SearchSource` 新增
   持久化字段 `siteIcon`，加载失败回退站点首字母。
2. **引用角标**：认官方 token `[citation:N]`（此前只认历史 `[ref_N]`，正文会残留字面量），
   两种都转成 `[N]` 内联芯片（浅强调底 + 强调色数字，与来源面板序号一致）；无对应来源的 token 丢弃；正文自带 token 时不再按 annotations 偏移
   补角标（避免一处两个编号）。移动端没有 hover：点角标打开来源面板并高亮该条。
3. **侧边栏**：会话按「今天 / 昨天 / 7 天内 / 30 天内 / 年月」分组（`core/utils/session_groups.dart`，
   按自然日差值、先按更新时间倒序）；行内去掉「服务商 · N 条消息」副标题，右侧加「更多」
   按钮（重命名/保密/删除仍复用原动作面板），长按保留。
4. **Markdown**：新增 `ui/widgets/markdown_theme.dart`，把 gpt_markdown 的代码块（语言标签 +
   复制按钮 + 中文提示）、表格（描边/表头底色/横向滚动）、引用块、行内代码、链接接到
   `AppColors` 语义 token；思考内容也改 Markdown 渲染（链接不可点防误触）。
5. **语音**：录音改为显式状态条（呼吸红点 + 「录音中 0:07」+ 五柱音量波形 + 取消），
   识别中显示「正在识别语音…」且可取消（操作代号丢弃在途结果）；朗读全局单实例
   （`TtsService.playingOwner`），播放中显示三根跳动音柱，结束后自动复位。
   顺带修复：识别结果此前会把已有草稿覆盖成一个空格，现在追加。

未跟 demo 的部分（移动端不适用或有代价）：分栏式搜索面板（手机改为底部面板）、
hover 卡片、Mermaid / KaTeX（gpt_markdown 不含 mermaid；公式未接）、继续生成（需 beta 接口
与 prefix）、会话导入导出（两端都缺，见 TD-004/TD-006）。
