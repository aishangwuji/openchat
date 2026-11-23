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
- **latest_reminder**：发 `What is today date and weekday`，回答
  `今天是2026年11月23日，星期一`（与系统日期、界面语言一致）；日志 `reminder: N user turns`
  随轮数递增（1→2→3），确认每轮都注入且格式含星期。
- **体积**：单个网页 signature 实测 2239 字符，远低于 200KB/条上限。

## 未验证（余下清单）

1. 开深度思考 + 联网搜索 + 阅读链接时走深度思考搜索、本轮不产生 `read_link`（官方语义）。
2. 切换到 Kimi / 小米 MiMo 时不注入 `latest_reminder`、不声明 `deepseek_read_url`（否则 400）。
3. 内容安全拒答 + `url_not_allowed` 组合下的界面文案（是否停在「正在阅读链接…」）。
4. 移动端（Flutter）同项目测：本机无模拟器/真机，只能静态验证，见 TD-004。
5. 跨零点后的 reminder 日期（应取新消息时间而不是会话创建时间）。

## 回归通过后

在本文件写结论（日期、模型、观察到的 `read_link` 数量）并把状态改为「已验证」，同时更新
`systemmap/balance-app.md` 与 `systemmap/balance-app-mobile.md` 对应小节的「验证」一行。
