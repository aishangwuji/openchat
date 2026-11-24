# TD-009 百智云 Cookie 等同登录态，鸿蒙端仍存 Preferences 明文；真实接口未实测

- 状态：待评估
- 原因：
  1. 鸿蒙端沿用资产页既有存储（Preferences `balance_prefs` 的 `key_baizhi`），存的是
     `baizhi_session=...` 整段 Cookie。它与 API Key 不同——**等同账号完整登录权限**
     （可读钱包、可签到、可看控制台），泄露后果比单个 Key 更重。移动端已进
     `flutter_secure_storage`（`key_baizhi`），鸿蒙端尚未迁移。
  2. 签到接口会触发验证码，应用按设计只跳转浏览器、不代签，因此「今日是否已签到」只能靠
     钱包接口的 `daily_temporary_credit_claimed` 间接确认；若厂商后续拆分独立签到状态接口，
     需要再对齐。
  3. 真实接口未在本机实测：没有用户 Cookie，`/api/v1/user/wallet/balance` 的 WAF 行为
     （`sl-session` 是否必需、UA 是否必须与浏览器逐字一致）只按接口文档实现。
- 影响范围：`BalanceApp/entry/src/main/ets/pages/Assets.ets`（录入与存储）、
  `services/BalanceService.ets`（Cookie 引擎）、`services/ProviderRegistry.ets`（百智云定义）；
  移动端对应 `mobile/lib/data/services/balance_service.dart`、`assets_page.dart`。
- 补偿：日志对 Cookie 只记长度（`maskCredential`）；凭据仅本机、不进 git；
  录入时本地校验 `baizhi_session` 片段；解析与边界语义由移动端同构单元测试覆盖
  （`mobile/test/balance_service_test.dart`）。
- 追踪：鸿蒙端待迁移 AssetStore / 加密存储（与 TD-001 同批）；真机回归时需确认
  ① 不带 `sl-session` 是否被 WAF 拦 ② 签到后 `daily_temporary_credit_claimed` 与临时积分
  是否同步变化 ③ Cookie 过期时提示是否准确（应显示「登录态失效」）。
