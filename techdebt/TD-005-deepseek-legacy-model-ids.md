# TD-005 旧 DeepSeek 模型名的会话未迁移

- 状态：待评估
- 影响范围：`BalanceApp/entry/src/main/ets/services/ChatStorageService.ets`（会话归一化）、
  `BalanceApp/entry/src/main/ets/pages/ChatView.ets`（模型回显）
- 首次登记：2026-11-19

## 现象 / 缺口

DeepSeek 官方已于 2026-07-24 下线 `deepseek-chat` / `deepseek-reasoner`，现行模型为
`deepseek-flash` / `deepseek-v4-pro`。仓库的兜底模型列表已在 `4f5fbd6` 修正，但**历史会话
持久化的 `modelId` 仍是旧名**：打开旧会话直接发送会收到 400（模型不存在），且模型选择器
里也找不到旧名条目，用户只能手动重选模型。

## 建议修法（二选一）

1. 加载时迁移：`normalizeSessions` 里对 `providerId === 'deepseek'` 的会话把旧名映射到
   `deepseek-flash`，一次性改写并回写存储。
2. 运行时校验：打开会话时检查 `modelId` 是否在 `availableModels` 中，不在则置空并要求用户重选
   （更保守，但要处理「模型列表尚未拉回」的时序）。

## 备注

联网搜索的 `deepseek_web_search` 只在 DeepSeek 可用，旧模型名会话即便不迁移也不会
影响其它服务商；该项与联网搜索本身无耦合，单独排期即可。

移动端兜底列表已于 2026-11-23 同步（`64170f4`，改为 deepseek-flash / deepseek-v4-pro）；
但**历史会话 `modelId` 的迁移/校验仍未做**，两端都在本 TD 范围内。

