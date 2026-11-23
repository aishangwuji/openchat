# TD-007 阅读链接 / 用户元信息真机联调

- 状态：部分已验证（2026-11-23，鸿蒙真机 6UNBB26820047956）；余下项见文末
- 影响范围：`BalanceApp/entry/src/main/ets/services/{ChatService,WebSearchService}.ets`、
  `BalanceApp/entry/src/main/ets/pages/{ChatView,Settings}.ets`、
  `mobile/lib/data/services/chat_service.dart`、`mobile/lib/state/chat_controller.dart`
- 首次登记：2026-11-23

## 怎么验的（可复现）

不用人工操作手机，全部走 hdc：

1. `devecocli build` → `hdc install -r entry-default-signed.hap` → `hdc shell aa start -a EntryAbility -b com.example.openchat`；
2. 界面读取：`hdc shell uitest dumpLayout -p /data/local/tmp/layout.json` + `hdc file recv`，
   从 JSON 的 `attributes.text` 拿到消息列表文本（替代截图，符合项目「不做截图验证」约定）；
3. 操作：`uitest uiInput click <x> <y>` / `uitest uiInput text '<消息>'`，
   坐标从 layout 的 bounds 反推（发送按钮 = 文本 `↑` 的 clickable 父节点）；
4. 日志：`hdc shell hilog` 过滤 `ChatService`，看
   `request tools=… readUrl=…`、`reminder: N user turns`、
   `server_tool_calls: N chars`（末块 signature 体积）、
   `server_tool_calls replay: N turns`（历史里实际回传的轮数）。

## 已验证

- **阅读链接主链路**：关思考、只声明 `deepseek_read_url`
  （`tools=1 webSearch=false readUrl=true`），发
  `Summarize https://example.com/ in one sentence`：
  出现 `server_tool_calls: 2239 chars`，回答带「1 个网页」来源，内容正确。
- **signature 多轮回传（客户端侧）**：追问 `Quote the first sentence of that page verbatim` 时
  `server_tool_calls replay: 1 turns`，说明带 signature 的 assistant 消息原样进了下一轮请求。
  - 该结论是**修复后**的结果：首次真机测试 `replay: 0`，定位到 `ChatView.sendMessage` 重建历史时
    漏拷 `serverToolCallsJson`（提交 `46f2601`），补齐后复测为 1。
- **服务端是否还原网页**：未能独立证明。追问「原文第一句」时模型给的是中文转述而不是英文原句，
  但 example.com 正文属于模型常识内容，无法区分「signature 生效」与「模型本来就知道」。
  要坐实需换一个模型不可能记住的页面（如当天新闻列表），当前未做。
- **思考 + 搜索 + 阅读链接组合**（tool 事件日志逐条取证）：
  - 开思考、关搜索、带 URL：`tool started kind=read_link action=read_link`，signature 2239 字符。
  - 开思考、开搜索、带 URL：`kind=deep_search action=search`（21 条来源）+ 4 次
    `kind=deep_search action=open_page`，**没有 read_link**，与官方「开思考且声明搜索时不单独读链接」一致。
  - 关思考、开搜索、带 URL 且明确要求「读取这个链接」：`read_link` 触发，signature 1429 字符。
  - 关思考、开搜索、只说 URL 不作要求：模型选择不调用任何工具直接作答（工具是否调用由模型判断，非缺陷）。
- **不可达链接**：发 `https://no-such-host-9f7a.example/`，模型回答
  「host 不存在或不可达」，没有卡在「正在阅读链接…」，也没有产生 signature；
  界面未崩溃。
- **内容安全拒答（部分）**：开启「模型内容安全」后发被禁请求（制作爆炸物），
  模型给出正常的对话式拒绝（英文说明无法提供），**没有**走到我们 `onRefusal` 的
  「内容未通过安全审核」文案——说明这次是模型级拒绝，不是 `safety_check` 命中
  （输入未触发 400、输出未 content_filter）。`url_not_allowed` 与 safety_check 命中
  文案仍未验证（设备在测试中途断开）。
- **留存体积优化**：深搜一次 `server_tool_calls` 实测 18070 字符，但都是无 signature 的
  `open_page`，不会进入后续上下文。改为只留存带 signature 的调用（`e2b72ed`）后：
  深搜不再留存任何内容，阅读链接仍为 2239 字符且下一轮 `replay: 1`。
- **latest_reminder**：发 `What is today date and weekday`，回答
  `今天是2026年11月23日，星期一`（与系统日期、界面语言一致）；日志 `reminder: N user turns`
  随轮数递增（1→2→3），确认每轮都注入且格式含星期。
- **体积**：单个网页 signature 实测 2239 字符，远低于 200KB/条上限。

## 未验证（余下清单）

1. 切换到 Kimi / 小米 MiMo 时不注入 `latest_reminder`、不声明 `deepseek_read_url`（否则 400）。
   真机模型选择器里当前只有 DeepSeek 两个模型，其它服务商未配 Key，无法测。
2. `safety_check` 命中的拒答文案（模型级拒绝已观察，拦截级未触发）。
3. `url_not_allowed`（安全审核拦截网页）：设备在测试中途断开，未执行。
4. 移动端（Flutter）同项目测：本机无模拟器/真机，只能静态验证，见 TD-004。
5. 跨零点后的 reminder 日期（应取新消息时间而不是会话创建时间）。
6. 思考+搜索组合下「同一轮既搜索又读用户链接」的用例——按协议本就不会发生，未构造。

## 回归通过后

在本文件写结论（日期、模型、观察到的 `read_link` 数量）并把状态改为「已验证」，同时更新
`systemmap/balance-app.md` 与 `systemmap/balance-app-mobile.md` 对应小节的「验证」一行。
