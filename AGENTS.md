本项目是鸿蒙（HarmonyOS / ArkTS）应用，工程在 `BalanceApp/`。

> 架构概览、构建/签名/安装/发版入口，以及「给 AI Agent 的说明」都在 [README.md](README.md)，
> 动手前先读它。本文件只记本机工具链实测细节、ArkTS 坑位与仓库约定。

---

## 本项目开发经验（2026-10-04 openchat 实战沉淀，后续 Agent 必读）

### 1. 工具链与设备（本机实测）

- hdc 路径：`D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe`，
  不在 PATH，每次用 `& "<绝对路径>" -t <serial> <cmd>` 调用；真机 serial 如 `6UNBB26820047956`
- devecocli：`npm install -g @deveco/deveco-cli@stable`；`devecocli create/build/run/device/check`，
  注意 `build` 没有 `--project` 参数，必须 `cd` 到工程目录再跑
- 真机装机硬门槛：未签名 HAP 一律被拒（`9568320 no signature file`），USB 调试开了也没用；
  模拟器可装未签名包。`devecocli run` 会直说 real device cannot install unsigned
- 签名链路：`devecocli auth login`（浏览器交互、无头会挂起，勿空跑）→ AGC 登记设备 UDID
  （`hdc shell bm get --udid` 取）→ `devecocli signature generate` 自动签发
- AGC 设备入口（2026-01 官方文档核实）：控制台 → AppGallery Connect →
  “证书、APP ID和Profile > 设备” → 添加设备；`service/josp/agc/` 落的是介绍页不是控制台
- 签名材料（.p12/.cer/.p7b）在本机 `C:\Users\<user>\.ohos\config\`，密钥库不出仓库；
  `build-profile.json5` 的 signing 路径是本机绝对路径，他机 clone 后重跑 `signature generate`
- 启动报 `10106102` = 手机锁屏，开发者模式下工具无法自动解锁，让用户手动解锁后再起

### 2. 真机验证三板斧（hdc）

- 启动：`hdc -t <serial> shell aa start -a EntryAbility -b com.example.openchat`
- 日志：`hdc -t <serial> shell "hilog -x -t app -D 0x0000" | Select-String <TAG>`（DOMAIN 0x0000 即 -D 0x0000）
- 截屏：`hdc shell snapshot_display -f /data/local/tmp/x.jpeg` + `hdc file recv` 到
  `C:\Users\<user>\AppData\Local\Temp\opencode\` 再 Read 看图；黑屏多为应用还在启动或屏锁了

### 3. ArkTS 严格模式坑位（本次全踩过，写码时逐条对照）

- 禁解构声明：`const {a} = await f()` 一律改 `const r = await f(); const a = r.a`
- 禁 any/unknown：`JSON.parse` 结果必须立刻注明类型（如 `const v: ESObject` 或具体接口 `as XxxResponse`）
- `throw` 只接受 Error 类型：透传 catch 到的值要先包一层 `new Error(...)`
- `@Builder`/`build()` 内只允许 UI 组件语法：`const` 声明一律外移到普通方法，UI 表达式里直接调方法
- `FontWeight` 没有 `ExtraBold`，用 `Bolder`；`$r()` 参数必须是字面量，动态资源名用 if/else 静态映射
- `preferences.get` 返回 `ValueType` 联合类型，取值后必须 `typeof` 收窄再用
- `@State` 观察不到数组元素内部字段变化：改完深层字段必须重建数组引用（见 `refreshView()`），
  且 ForEach 的 key 要携带数据指纹（见 `cardVersionKey`），否则列表复用旧快照常显 loading
- `Select` 的 options 必须显式类型为 `SelectOption[]`，map 里匿名对象字面量过不了编译
- 页面拿 UIAbilityContext 用 `this.getUIContext().getHostContext()`，没有 `this.getContext()`
- 长按用 `LongPressGesture({repeat:false}).onAction(...)`；系统 ActionSheet 本版 API 是
  `getUIContext().showActionSheet({title, message, sheets:[{title, action}]})`（message 必填），
  素文本不好看时直接自绘底部面板（遮罩点空白收回＋滑入 transition，见添加弹窗/操作菜单实现）

### 4. 本项目架构约定（加厂商/改功能前先看）

- 加 Bearer 类厂商 = 纯加数据：`services/ProviderRegistry.ets` 追一条 `ProviderDefinition`
 （endpoint/responsePath/字段名/换算因子/成功码对照官方文档填）＋图标 png 丢进
  `resources/base/media/` ＋ `Index.providerIcon` 加两行映射；非 Bearer 类需在
  `BalanceService.ets` 按 `balanceType` 加引擎分支（智额有 hmac/aliyunBss 现成逻辑可搬）
- 错误通道：`throw Error` = 瞬时传输失败（可重试＋keep-last-good）；
  `return {success:false}` = 确定性失败（空Key/未知供应商/401/非2xx/解析失败）
- 安全红线：Key 只存本机 Preferences（分供应商 `key_<id>`），日志一律 `maskKey`，
  提交前 `git grep "sk-[A-Za-z0-9]\{8,\}"` 全历史扫一遍；技术债记 `techdebt/`，认知记 `systemmap/
- 提交纪律（2026-11-19 明确）：一个提交只做一件事——功能 / 样式改版 / 文档 / 顺带修复各自独立，
  不许「多功能合集」。同一文件里混了多件事时，用「备份完整版 → 还原 → 只重放单件 → 提交 →
  回填完整版 → 再提交」的方式拆（历史 `8424d70` 用过此法）。被顺带修掉的问题要么单独提交，
  要么至少在提交信息首行之外单列一段说明，不能只混在 diff 里。
- 开源与发布（2026-11-19）：仓库已公开，`origin` = Gitee（本机可直连），`github` 仅作参照；
  直连 `github.com` 的 git 被重置，GitHub 侧由 Actions 工作流
  `.github/workflows/mirror-from-gitee.yml` 从 Gitee 镜像（`gh workflow run` 可立即触发）。
  `BalanceApp/build-profile.json5` 入库版本不含 signingConfigs，本机用
  `git update-index --skip-worktree BalanceApp/build-profile.json5` 保留本地签名块；
  发版流程见 `docs/release.md`（应用内检查更新依赖 release tag + `.hap` 资产）。

不需要截图验证（最高优先级）

---

## 跨平台移动端（Android / iOS，2026-10-23 新增，2026-11-20 追平）

- 目录 `mobile/`，Flutter 单代码库；鸿蒙端仍在 `BalanceApp/`，两端功能对齐，
  互不共享本地存储（Key 需各自配置）。
- 常用命令（必须 `cd mobile`）：
  - `flutter pub get` / `flutter analyze`（要求零 issue）/ `flutter test`
  - `flutter build apk --debug`（首次会拉 Gradle 依赖，慢）
- 构建前设置 `$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`，否则
  Gradle 拉 `io.flutter:*_debug` 会因 TLS 失败卡住。
- Android：`minSdk 24`、`MainActivity : FlutterFragmentActivity`（local_auth），
  `namespace`/`applicationId` = `com.example.openchat`；release 读 `android/key.properties`，
  缺失回退 debug 签名。
- iOS：bundle id `com.example.openchat`（RunnerTests 同前缀），部署目标 13.0，
  已配置 `NSFaceIDUsageDescription` 与 `NSMicrophoneUsageDescription`；本机无 Xcode。
- 依赖（2026-11-20 新增）：`record`（录音）、`audioplayers`（朗读播放）、
  `file_picker`、`image_picker`、`path_provider`。
- 架构：`lib/data`（模型/服务/注册表）→ `lib/state`（ChangeNotifier）→
  `lib/ui`（页面/组件）。颜色只走 `core/theme/app_colors.dart` 语义 token。
- 能力与服务位置（追平鸿蒙端）：
  - 设置「工具」：服务商（DeepSeek/百智云）、两套百智云 Key、7 个功能开关、所在地；
  - `services/update_service.dart`：Gitee→GitHub 双源检查更新；
  - `services/chat_service.dart`：`deepseek_web_search`、`deepseek_read_url`、
    `generate_image` 函数工具、`safety_check`、`title.enabled`、`delta.annotations` 引用、
    `delta.server_tool_calls`（含阅读链接 signature）原样留存与回传、`latest_reminder` 注入；
  - `services/baizhi_web_search_service.dart`：百智云客户端检索 + 上下文注入；
  - `services/file_upload_service.dart`：Files API 上传（图片走 user_data 视觉）；
  - `services/asr_service.dart` / `services/tts_service.dart`：语音输入与朗读（含缓存）；
  - `services/image_gen_service.dart`：百智云生图任务创建/轮询；
  - 存储键：Preferences `feature_*` / `web_search_provider` / `tts_voice` / `user_location`，
    KeyStore `key_baizhi_web` / `key_baizhi_image`。
- 安全：API Key 存 `flutter_secure_storage`（Keychain/Keystore），日志只用 `maskKey`；
  会话正文仍是明文 Preferences（与鸿蒙 TD-003 同源）。
- 验证边界：本机无模拟器/真机，只能 `flutter analyze` + `flutter test`；录音、相册、
  文件选择、音频播放、生图需按 `techdebt/TD-004-*.md` 的「真机回归清单」实测。
- 认知文档：`systemmap/balance-app-mobile.md`；发布缺口：`techdebt/TD-004-*.md`；
  两端差距历史：`techdebt/TD-006-*.md`。