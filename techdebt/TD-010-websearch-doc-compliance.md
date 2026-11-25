# TD-010 联网搜索功能官方文档合规审核

- 状态：主要缺陷已修复（2026-11-25）；遗留项待排期
- 影响范围：`BalanceApp/entry/src/main/ets/services/{ChatService,WebSearchService}.ets`、
  `BalanceApp/entry/src/main/ets/pages/ChatView.ets`、`BalanceApp/entry/src/main/ets/models/ChatModels.ets`；
  `mobile/lib/data/services/chat_service.dart`、`mobile/lib/state/chat_controller.dart`、
  `mobile/lib/data/models/chat_models.dart`、`mobile/lib/ui/widgets/message_bubble.dart`
- 首次登记：2026-11-25

## 为什么审

用户要求按官方《联网工具》Chat Completions 章节逐条核对两端实现。审核基线 HEAD `8c7af25`，
只读代码 + 对照文档；真机与模拟器均未参与（移动端本机无设备，见 TD-004）。

## 修复前结论

| 检查点 | 鸿蒙端 | Flutter 端 |
|---|---|---|
| 请求构造（tools/thinking/safety_check/title/tool_choice/web_search_options） | 与文档一致 | 与文档一致 |
| `server_tool_event` / `annotations` / `server_tool_calls` / `title` 解析 | 一致 | **全部被 `hasPayload` 过滤丢弃**（事件只在有正文时上交） |
| 多轮 `server_tool_calls` 回传（signature） | 一致（裁剪非 signature 调用） | 代码齐全，但 signature 从未落库 → 实际失效 |
| 400（输入审核 / 上下文超限 / tools 冲突） | **静默按成功空回答收尾** | 状态码检查 + 错误文案 |
| `finish_reason=length` | 静默按成功 | 静默按成功（注释明确忽略） |
| 生成中失败（末块 error、无 `[DONE]`） | 未处理 | 未处理 |

## 已修复

1. `8125727` fix(mobile)：`hasPayload` 纳入搜索/引用/标题/拒答/工具调用等载荷；
   `_parseChunk` 不再把 `delta` 当解析前提；`streamChat` 增加仅测试用的 `clientFactory`，
   新增 `test/chat_stream_test.dart`（mock SSE 锁定「无正文增量的事件也能到达上层」）。
2. `99820a1` fix(mobile)：`finish_reason=length` → `truncated` → 气泡下方提示。
3. `dddbbc6` fix(mobile)：DeepSeek 多轮不再回传 `reasoning_content`，空的思考回合整体丢弃；
   Kimi / MiMo 保持原行为。新增 `history_replay_test` 用例。
4. `bed7302` fix(chat) 鸿蒙端：保留响应原文，非 SSE 时解析 `{"error":{"message":...}}`；
   末块 `error`（生成中失败）同样提取；`finish_reason=length` 通过 `onIncomplete`
   在气泡下方提示；`settled` 防 err 回调与 `dataEnd` 重复收尾。

## 遗留（未改）

1. **图片搜索 `image_url` 未展示**（两端）：文档说明该字段仅供展示，可先不做。
2. **来源口径**：鸿蒙端把深搜 `open_page` 的页面也并入 `sources` 并计入「N 个来源」，
   与 `citations`（真正被引用的来源）口径不一致，会高报来源数。
3. **模型未限定 `deepseek-flash`**：文档写「请使用 deepseek-flash」，代码同时放开
   `deepseek-v4-pro`（注释称实测可用）。属放宽而非报错。
4. **历史截断可能丢 signature**：20 条 / 12000 字预算在长会话里会丢掉带 signature 的
   助手消息，后续轮次读不到旧网页。
5. **`server_tool_calls` 非字面「原样」**：回传前裁剪成只含 signature 的调用（服务端语义等价，
   文档也允许整体丢弃该字段，但不等同于逐字节回传）。
6. **搜索失败提示偏乐观**：`error_code=unavailable` 时鸿蒙端显示「已检索 N 个来源，正在整理答案…」，
   移动端不更新提示（停在「正在联网搜索…」）。
7. **400 真机行为未验证**：鸿蒙 `requestInStream` 对 4xx 是否走 err 回调未知；若走 err，
   新增的响应体解析不会触发，界面显示「网络请求失败: ...」而不是 `error.message`。

## 待真机回归

- 移动端真实 SSE：来源卡片、引用角标、服务端标题、阅读链接 signature 落库与下一轮回传。
- 鸿蒙端 400（输入内容审核）与 `finish_reason=length` 的界面呈现。
- 恢复默认设置后回归，避免测试残留开关（参照 TD-007「现场设置」）。
