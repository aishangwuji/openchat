# TD-007 阅读链接 / 用户元信息未做真实接口联调

- 状态：待验证（代码与构建已完成，运行期未取证）
- 影响范围：`BalanceApp/entry/src/main/ets/services/{ChatService,WebSearchService}.ets`、
  `BalanceApp/entry/src/main/ets/pages/{ChatView,Settings}.ets`、
  `mobile/lib/data/services/chat_service.dart`、`mobile/lib/state/chat_controller.dart`
- 首次登记：2026-11-23

## 为什么没验

本机没有可用的 DeepSeek API Key（环境变量未设置、也没有已登录设备可读 Key），
`hdc list targets` 为空（无真机），移动端也没有模拟器。因此这两项**只做了协议实现与
静态校验**：鸿蒙端 `hvigor assembleHap` 通过，移动端 `flutter analyze` 零 issue、
`flutter test` 30 项通过。没有对真实 SSE 抓过一次包。

## 必须回归的点（按优先级）

1. **阅读链接主链路**（关思考 + 只声明 `deepseek_read_url`，或关思考 + 搜索也声明）：
   发一条带 URL 的消息，确认出现 `read_link` 调用与「正在阅读链接…」提示、来源卡片可点。
2. **signature 多轮回传**（最关键）：读完链接后追问「把网页第一句原文贴出来」。
   若模型答不出原文，说明 `server_tool_calls` 没被正确回传（检查请求体里 assistant 消息
   是否带 `server_tool_calls` 且含 `signature`）。
3. **开思考 + 搜索 + 阅读链接**：确认走深度思考搜索、本轮不出现 `read_link`
   （官方语义，不是 bug）。
4. **`latest_reminder` 格式**：抓请求体确认 `content` 形如 `2026-11-23,星期一,新加坡,App,中文`；
   跨零点后再发一条，确认日期取的是新消息的时间而不是会话创建时间。
5. **服务商隔离**：切到 Kimi / 小米 MiMo 发消息，确认请求里既没有 `latest_reminder`
   也没有 `deepseek_read_url`（否则会 400）。
6. **体积**：读一个长网页后看会话 JSON 体积、`serverToolCallsJson` 是否触发 200KB 丢弃；
   鸿蒙端 Preferences 单值写入是否仍正常（历史会话列表能正常保存/加载）。
7. **拒答组合**：开内容安全后读一个会被拦的链接，确认 `url_not_allowed` 时界面给的是
   「链接读取失败」而不是卡在「正在阅读链接…」。
8. 移动端同样跑 1-7（本机只能静态验证，见 TD-004）。

## 回归通过后

在本文件写结论（日期、模型、观察到的 `server_tool_use`/`read_link` 数量）并把状态改为
「已验证」，同时更新 `systemmap/balance-app.md` 与 `systemmap/balance-app-mobile.md`
对应小节的「验证」一行。
