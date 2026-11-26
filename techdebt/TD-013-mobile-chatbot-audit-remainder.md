# TD-013 移动端按官方 Chatbot 文档核验后的遗留

- 状态：待处理
- 影响范围：`mobile/lib/data/services/chat_service.dart`、`chat_controller.dart`、
  `file_upload_service.dart`、`tts_service.dart`、`ui/widgets/search_sources.dart`
- 首次登记：2026-11-26

## 背景

按官方《构建 Chatbot》九项能力与 Chat Completions 契约逐条核验后，P1 缺口已修完
（模型锁定、历史保留、纯附件发送、流式失败、失败提示、TTS/ASR/文件上限），
余下为口径、长尾体验与真机回归项。

## 遗留

1. **来源计数口径偏高（P2）**：深搜 `open_page` 打开的网页被并入 `sources`，
   「参考了 N 个网页」把没有被引用的页面也算进去，与 `citations` 口径不一致。
   修法建议：区分 `cited` 与 `consulted`，摘要行只按 citations 去重计数；
   面板仍可展示全部来源。
2. **长会话仍可能丢上下文（P2）**：预算已放宽到 60 条/100000 字，但更长的会话仍会
   丢掉最早的附件轮次或 signature 轮次。修法建议：给「带 file_id / signature」的历史
   单位更高保留优先级，或在超预算时显式提示用户。
3. **附件全量读内存（P2）**：`readAsBytes` 会把 100 MiB 文档整体读入内存，低端机有
   OOM 风险；上传也没有进度、取消入口与服务端删除。修法建议：分块流式上传、
   上传进度、删除 Files API 文件。
4. **图片搜索 `image_url` 未展示（P3）**：官方说明该字段仅供展示，可后做。
5. **`server_tool_calls` 非逐字节回传（P3）**：仍裁剪为只含 signature 的调用；服务端
   语义等价，文档允许丢弃，暂按可接受处理。2026-11-26 已避免「单个超大 signature
   拖垮整轮」。
6. **TTS 仍为整段合成（P3）**：官方还提供 WebSocket 流式合成，当前整段请求已够朗读
   回答；超长文本按 10000 计费字符截断，未做分片续读。
7. **`safety_tokens` 未展示（P3）**：token 统计整体未做，不构成协议违反。
8. **演示客户端长尾（P3）**：继续生成（beta `prefix`）、会话导入/导出、Mermaid、
   全量中英文界面仍未做；不在九项功能表内。
9. **ASR 120 秒只在 UI 收敛（P3）**：录音计时到点自动停；若将来新增其它音频入口，
   `AsrService` 仍应补 WAV 时长校验。
10. **TTS 缓存无上限（P3）**：落在临时目录，系统可回收；未按容量清理。
11. **真机回归未完成（P1，发版前）**：真实 SSE、文件解析、图片视觉、语音/朗读、
    拒答形态、`url_not_allowed` 提示、20 文档上限仍需按 `TD-004` 清单逐项打勾。

## 验证

- 2026-11-26：`flutter analyze` 0 issue、`flutter test` 97 项、`flutter build apk --debug` 成功。
- 本轮只做静态与单测；未在真机发起真实请求（需要用户自己的 API Key）。
