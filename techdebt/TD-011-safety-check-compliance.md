# TD-011 模型内容安全（safety_check）实现审核

- 状态：主要缺陷已修复（2026-11-25）；余项见文末
- 影响范围：`BalanceApp/entry/src/main/ets/services/ChatService.ets`、
  `BalanceApp/entry/src/main/ets/pages/ChatView.ets`；
  `mobile/lib/data/services/chat_service.dart`、`mobile/lib/state/chat_controller.dart`
- 首次登记：2026-11-25

## 审核依据

官方《模型内容安全》：

- `safety_check.level` 只能是 `low` / `high`；`low` 与不传等价；
- 开启后审核输入与输出；输入命中返回 `400 Content Exists Risk`，输出命中以拒答结束；
- Chat Completions 的输出拒答：`finish_reason=content_filter`，`content` 为空、
  不返回 `annotations`、`server_tool_calls` 保留、各步思考清空；图片被拦时说明在
  `message.refusal`（流式为末块 `delta.refusal`）；
- 已经流式下发的文本无法撤回，客户端必须删除已展示回答并改为自己的拒答文案；
- 审核期间连接保持打开；拒答前 token 照常计费。

## 修复前结论

| 检查点 | 鸿蒙端 | Flutter 端 |
|---|---|---|
| `safety_check` 只在 DeepSeek、只在开关开启时声明 `high` | ✅ | ✅ |
| 未设置 `tool_choice`（单独使用时只能 auto/none） | ✅ | ✅ |
| 输入 400 `Content Exists Risk` 可见 | ⚠️ 上一轮已修成显示原始英文 | ✅ 显示原始状态码 + JSON |
| 输出 `finish_reason=content_filter` 解析 | ✅ | ✅ |
| 输出拒答提示 | ❌ **onRefusal 之后 onComplete 把 status 改回 success，提示被吞，只剩空消息** | ⚠️ 有提示，但文案写死、丢弃服务端图片拦截说明 |
| 拒答时清空正文 / 思考 | 正文、思考都清 | 只清正文，思考仍展示 |
| 拒答时保留 `server_tool_calls` | ✅ | ✅ |
| 引导用户关闭安全开关 | ❌ 提示里写「可在设置关闭内容安全后重试」 | ❌ 同样引导 |

鸿蒙端的「静默」就是上表第 6 行：`onRefusal` 先把 `status` 设为 `error` 并写
`errorMessage`，紧跟着的 `onComplete` 无条件 `status = 'success'`，渲染层只对
`status === 'error'` 显示错误块，于是拒答变成一条空白的成功消息。

## 已修复

1. `0f5a860` fix(mobile)：新增 `safetyNotice()`（通用文案 + 服务端 detail，图片拦截时原样附上）；
   拒答时清空正文与思考、保留 `server_tool_calls`；`400 Content Exists Risk` 映射为同一类
   安全提示，不再暴露状态码/JSON；移除「关闭内容安全后重试」的引导。新增 `test/safety_test.dart`。
2. 鸿蒙端（本次提交）：`ChatService.safetyNotice()` / `errorNotice()`；`ChatView.onRefusal`
   改用统一文案并清理搜索态；`onComplete` 在 `status === 'error'` 时不再改回 success，
   拒答状态与提示才能落库/展示；输入 400 映射为安全提示。验证：`devecocli build` 通过。

## 遗留

1. **未展示 `safety_tokens`**：Chat Completions 的 `usage.completion_tokens_details.safety_tokens`
   没有读取（两端 token 统计整体下线），不构成协议违反。
2. **拒答原因不可知**：官方明确不返回具体原因；图片拦截只给索引路径，界面只能原样附注。
3. **非流式路径**：鸿蒙 `nonStreamChat` 未处理 refusal（当前无调用方），移动端无同类接口。
4. **真机未验证**：输入 400 的实际到达方式（鸿蒙 `requestInStream` 对 4xx 的处理）、
   流式末块 `delta.refusal` 的实际形态、图片拦截样本（需合规红队环境，不随手构造）。
5. **历史中的拒答消息**：状态与文案落库后，重新打开会话仍显示提示；`safetyBlocked`
   之类的专用字段未引入，样式沿用错误块（红色「失败: …」）。

## 待真机回归

- 开启内容安全，发命中输入的样本 → 应显示「本次对话未通过内容安全审核，请调整内容后重试」，
  而不是空白回答或 `Content Exists Risk` 原文。
- 构造输出命中（如合规红队样本）→ 已流式显示的正文应被清空，改为拒答文案，
  且 `server_tool_calls` 仍随历史回传。
- 图片输入被拦 → 提示中带 `messages.x.content.x` 定位。
