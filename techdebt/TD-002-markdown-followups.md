# TD-002 Markdown 渲染后续项（FluidMarkdown 接入后）

- 状态：待评估
- 背景：`fluid-markdown@1.0.11` 已接入（`entry/oh-package.json5`），GFM + 流式
  Typing + 代码高亮/复制 + 主题映射已落地（见 `systemmap/balance-app.md` Markdown 条目）。
- 后续项：
  1. ~~LazyForEach + IDataSource 迁移~~ 已落地（2026-10-19）：
     `services/ChatMessageDataSource.ets` + `LazyForEach` + `cachedCount(2)`，
     数据源按结构性/局部 key 变化分级刷新，流式增量仍由 controller 驱动。
     剩余：`@Reusable` 实例复用（滚动回收复用组件，进一步降滚动开销）仍待做。
  2. 引用来源：~~内联角标/来源面板~~ 已落地（2026-11-19，`595db48`）：`annotations` 的
     `start_index`/`end_index`（Unicode 码点）随消息持久化，`MarkdownService.injectCitations`
     换算成 UTF-16 下标后在正文插 `[N](#cite-N)`（跳过围栏代码块、从后往前插）；
     来源为「图标胶囊 + N 个网页」，点开展开明细。剩余一项：
     - ~~**阅读链接**：`deepseek_read_url`~~ 已落地（2026-11-23）：末块
       `delta.server_tool_calls`（含 `signature`）以原文存 `ChatMessage.serverToolCallsJson`，
       `buildApiMessages` 原样回传；只读了链接没吐正文的回合也保留。真实接口回归见 TD-007。
  3. Worker 解析实测：库内 parse 为异步合并，解析线程归属未验证；超长消息先观察是否卡顿。
  4. 表格横滚：库采用列宽自适应（`cellMaxWidth` 主题可调），无溢出故未做外层横滚；若出现宽表溢出再议。
  5. LaTeX：库鸿蒙端明确未支持（Known Issues），公式需求如提出需另选方案。
- 影响范围：`components/MarkdownBody.ets`、`pages/ChatView.ets`（气泡/key/驱动器）。
