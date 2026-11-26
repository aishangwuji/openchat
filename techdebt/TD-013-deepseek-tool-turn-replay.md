# TD-013 带 tools 的 DeepSeek 请求：历史工具轮回传协议待验证

- 状态：待验证（2026-11-26 登记；未修改行为）
- 影响范围：`BalanceApp/entry/src/main/ets/services/ChatService.ets`（`buildApiMessages`）、
  `BalanceApp/entry/src/main/ets/services/WebSearchService.ets`（`serializeServerToolCalls`）
- 关联：`systemmap/balance-app.md`「长会话空回答可观测性修复」；TD-010（阅读链接合规）

## 现象 / 疑点

用户反馈长会话（约 50 轮）后看不到 AI 回答。空回答静默收尾已在 2026-11-26 修掉（会显示明确
错误），但**触发源**仍有两个协议层面的疑点：

1. **思考模式下未回传历史 `reasoning_content`**
   - 官方《思考模式》：「携带了 `tools` 参数的请求，在后续所有请求中，必须完整回传
     `reasoning_content` 给 API……若未正确回传，API 会返回 400 报错」。
     报错文案：`The reasoning_content in the thinking mode must be passed back to the API.`
   - 本应用默认每个 DeepSeek 请求都声明 `deepseek_read_url` + `generate_image`
     （`ChatView.ets` 的 `enableReadUrl` / `enableImageTool` 默认开关为 true），而
     `buildApiMessages` 对 DeepSeek 的 `preserveThinking` 传 `false`，历史思考一律丢弃
     （2026-11-20 实测「回传思考导致答题串味」后定的策略）。
   - 社区实现（qwen-code、n8n）的做法是：**只对带 tool_calls 的 assistant 轮**回传
     `reasoning_content`（模型没下发思考时也要补空字符串字段），普通轮不回传。

2. **`server_tool_calls` 被裁剪而非原样回传**
   - 官方联网工具要求「此前响应中的 `server_tool_calls` 原样回传」。
   - `WebSearchService.serializeServerToolCalls` 只保留带 `signature` 的 call、丢弃无
     signature 的 step，再重新 `JSON.stringify`。裁剪后 `index` 可能不连续、缺少 step，
     是否被服务端判为非法结构未知（初版动机是控制会话 JSON 体积，实测一次深搜 18KB）。

两个疑点都只在「历史窗口里出现工具轮」后才可能触发，这与「前面几十轮正常、某一轮之后
持续没有回答」的现象吻合；但本机 DeepSeek Key 余额为 0、无鸿蒙真机在线，未能取证到 400。

## 验证方法（下一次真机复现）

1. 抓 `hdc shell hilog`，过滤 `ChatService`：
   - `request: history=… web=… image=… readUrl=… thinking=…`（确认工具声明）
   - `stream error: …`（400 时服务端 message 会原样打印）
   - `stream end: finish=… sse=… chunks=… output=…`（空流/资源不足）
2. 若 400 message 含 `reasoning_content` → 疑点 1 成立；含 `server_tool_calls`/`messages` →
   疑点 2 成立。

## 修复预案（取证后再动）

- 疑点 1：`buildApiMessages` 增加 `replayToolTurnReasoning`：仅对带 `serverToolCallsJson`
  的 DeepSeek assistant 轮回传 `reasoning_content`（无思考时回传空串字段），普通轮维持现状，
  避免重新引入「串味」。
- 疑点 2：改为「整轮保留或整轮不回传」：超限时丢弃该轮（连同它的 user 提问）而不是回传
  残缺 `server_tool_calls`；体积问题用会话级预算解决，不在协议字段上裁。
