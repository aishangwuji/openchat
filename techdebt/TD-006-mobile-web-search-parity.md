# TD-006 移动端（Flutter）与鸿蒙端能力对齐

- 状态：已完成（2026-11-20，差距项全部落地，剩余长尾见文末）
- 影响范围：`mobile/lib/data/services/chat_service.dart`、`mobile/lib/state/chat_controller.dart`、
  `mobile/lib/ui/pages/chat_page.dart`、`mobile/lib/ui/widgets/message_bubble.dart`
- 首次登记：2026-11-19

## 现象 / 缺口

鸿蒙端已在 `4f5fbd6` 接入 DeepSeek 服务端联网搜索（`deepseek_web_search`）：
请求声明 tools、解析 `server_tool_event` 展示检索进度、解析末块 `annotations` 与搜索来源、
按 url 去重持久化并渲染来源卡片。**Flutter 端尚未对齐**，两端功能出现已知差异。

## 对齐要点（按鸿蒙端契约移植，不另起设计）

1. `ChatRequestOptions` 加 `enableWebSearch`；`_buildPayload` 在 DeepSeek 且开关为真时加
   `tools: [{'type': 'deepseek_web_search'}]`。
2. `ChatStreamEvent` 扩展搜索事件（`server_tool_event` 的 started/completed）与
   `annotations` 来源；解析规则与 `WebSearchService` 一致（含「call_completed 不带 kind」这一实测结论）。
3. 消息模型加 `sources`（持久化）与 `searchState`/`searchHint`（不持久化）；
   `ChatStorageService` 归一化时校验 http/https、按 url 去重、上限 24。
4. UI：开关胶囊与「深度思考」并排、检索进度文案、正文下方来源卡片（点击开浏览器）；
   开关值存 `preferences_service` 的 `web_search_enabled`，仅 DeepSeek 展示。
5. 对齐后跑 `flutter analyze`（零 issue）+ `flutter test`；新增的解析/去重用例优先覆盖
   mergeSources 的「先到先得、后到补空」语义。

## 备注

鸿蒙端在 `595db48` 又补了正文引用角标、来源胶囊与语音朗读（`TtsService` + 设置页
「语音 > 朗读音色」），这些同样尚未在移动端出现。`86619ea` 之后输入区也改成官方同款
卡片（能力胶囊进卡片、蓝色胶囊样式、右下发送/停止），`4e195f8` 接入了 DeepSeek Files API
文档问答（「+」上传、消息携带 file_id、历史回放）。建议与联网搜索一起对齐：
引用角标（码点→UTF-16 + 跳过代码块）、来源胶囊、TTS 朗读与音色设置、输入卡片样式、
文件上传与 content 数组消息、图片视觉输入（user_data + file 块）与拍照/相册入口、
语音输入（录音 WAV + `/v1/tools/asr`，点按录音）。

反向差异（移动端有、鸿蒙端已删除）：上下文净化（TopicGate/Jev）。2026-11-19 鸿蒙端判断该功能
多余并整体移除，移动端 Flutter 代码仍保留，做对齐时应一并删除，避免两端能力分叉。

移动端当前无真机/模拟器可跑（见 TD-004 第 3 条），本轮按用户选择先只做鸿蒙端，
对齐时至少要做到 `analyze` + `test` 通过，运行期验证与 TD-004 一并排期。

## 2026-11-20 现状快照（移动端尚未跟进）

结论：**Android / iOS（`mobile/`）没有跟进 2026-11-19 的鸿蒙端改动**，只改了显示名
（`7d3fe88`：Android label / iOS CFBundleDisplayName / Flutter title 改为 openchat），
包名仍是 `com.example.balanceapp`。功能层面的差距如下：

| 能力 | 鸿蒙端 | 移动端 | 对齐工作量 |
|---|---|---|---|
| 应用身份 | openchat / `com.example.openchat` | 显示名 openchat，包名未改 | 小（Gradle/pbxproj/MainActivity 包路径） |
| 应用内检查更新（Gitee→GitHub 双源） | 已做（`2f87b2f`） | 无 | 中（服务 + 设置入口 + 弹窗） |
| 设置「工具」分组 / 服务商 / Key 表单 | 已做（`57da565`） | 无 | 中 |
| 功能开关（标题/文件/语音输入/朗读/生图/内容安全） | 已做 | 无 | 小-中 |
| 联网搜索（DeepSeek 服务端工具） | 已做 | 无 | 中（本文件第 1-5 条） |
| 百智云联网搜索（客户端检索注入） | 已做 | 无 | 中 |
| 正文引用角标 / 来源胶囊 | 已做 | 无 | 中 |
| 文件解析（Files API + 附件回放） | 已做 | 无 | 中 |
| 图片视觉输入（user_data + 拍照/相册） | 已做 | 无 | 中 |
| 语音输入（录音 → ASR） | 已做 | 无 | 中-大（录音 + 权限 + WAV 封装） |
| 朗读回答（TTS + 本地缓存） | 已做 | 无 | 中 |
| 生图（函数工具 + 轮询 + 结果展示） | 已做 | 无 | 大 |
| 模型内容安全（safety_check + 拒答） | 已做 | 无 | 小 |
| 上下文净化（TopicGate/Jev） | 已删除 | 仍在 | 小（反向差异，删除即可） |
| 蓝白聊天 UI / 输入卡片 | 已做 | 旧版配色 | 中 |

处理方式二选一，由用户决定后再开工：

1. **全量追平**：按上表逐项移植，建议顺序「身份 → 更新机制 → 设置工具/开关 → 搜索/引用 →
   语音 → 生图 → 内容安全 → 删 TopicGate」，每项单独提交并跑 `flutter analyze` + `flutter test`；
2. **关键子集**：先做「身份 + 更新机制 + 设置与开关 + 联网搜索」，其余登记为后续版本，
   移动端在 README 标注「能力滞后于鸿蒙端」。

无论哪种，移动端当前没有可用的真机/模拟器（见 TD-004 第 3 条），只能做静态校验。

## 2026-11-20 追平结果

上面「差距清单」中的项目已全部落地（提交 `6d61e0d`、`356fc53`、`64f1fa3`、`823009d`、
`28978c7`、`98569ab`、`7c0adfe`、`3891344`、`3d1a526`、`9ca04c8`）：

- 应用身份、检查更新、设置「工具」与 6 个开关、联网搜索（DeepSeek + 百智云）、引用角标与来源胶囊、
  文件解析、图片视觉、语音输入、朗读（含音色）、生图、内容安全；
- TopicGate/Jev 已从移动端删除，与鸿蒙端一致。

仍存在的长尾差异（不影响主流程，后续按需处理）：

1. 聊天正文版式/配色的细节差异（移动端沿用 Material 结构，未逐像素对齐鸿蒙蓝白卡片）；
2. 移动端没有「分享/导出会话」入口（鸿蒙端也没有，属于双端共同缺口）；
3. 语音、相册、文件选择、音频播放与生图只做了静态验证，需要真机/模拟器实测。

## 2026-11-23 转折：移动端开始反向领先

移动端参照官方 chat-demo 重做对话页（来源面板、时间分组、Markdown 主题、语音状态条、
朗读单实例），这些**鸿蒙端还没有**，两端从「移动端追鸿蒙」变成互有领先，
差异与做法见 [TD-008](TD-008-harmony-chat-demo-parity.md)。