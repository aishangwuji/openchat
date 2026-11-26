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
- Cookie 类厂商模板（2026-11-24 百智云落地，两端同构）：`balanceType: CookieSession` +
  `credentialKind: Cookie` + `credentialRequiredFragment`（本地校验，如 `baizhi_session`）+
  `userAgent`（与取 Cookie 的浏览器一致，防 WAF）；请求走 `Cookie` 头而非 Authorization，
  解析复用同一份 `parseBody`，别复制字段映射。积分类金额用占位符币种 `CREDITS`
  （`unitLabel` 显示「积分」），避免与人民币相加。需要人机验证的写操作（签到）只做跳转，
  应用不代签。图标由 `scripts/make_baizhi_icon.py` 生成（PIL，两端产物一致）。
  **余额专用供应商必须 `chatCapable: false`**：注册表同时驱动资产页与聊天页，不置 false 时
  ChatView 会把 Cookie 当 API Key 发到 `/v1/models`、`/v1/chat/completions`（2026-11-24 实测踩过，
  用 `chatProviders()` 过滤）。
- 对话工具一律「声明式」（2026-11-25 用户明确）：`generate_image` 只按「功能开关 + 服务商能力」
  （`featureImage && providerId == 'deepseek'`）声明，是否画由模型自判；**不要再加关键词表**
  （旧 `wantsImage/wantsImageWithContext` 已删——关键词覆盖不到「生成一张图片」这类说法，
  直接导致触发不了）。缺百智云生图 Key 时走执行阶段报错（气泡里显示「未配置…Key」），
  不要靠不声明工具来静默兜底。联网搜索 `deepseek_web_search` 同形：开关一打开就声明，模型决定搜不搜。
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
- Android：`minSdk 24`、`MainActivity : FlutterFragmentActivity`（local_auth）；
  `namespace = com.aishangwuji.openchat`，但 `applicationId` 保持 `com.example.openchat`
  （安装身份，v1.0.4 起冻结；v1.0.3 改新包名导致 v1.0.2 用户升级读不到旧数据，已撤回，
  换包名必须先做迁移，见 `techdebt/TD-015`）；启动命令
  `adb shell am start -n com.example.openchat/com.aishangwuji.openchat.MainActivity`；
  release 读 `android/key.properties`，缺失回退 debug 签名。
- iOS：bundle id `com.example.openchat`（RunnerTests 同前缀），部署目标 13.0，
  已配置 `NSFaceIDUsageDescription` 与 `NSMicrophoneUsageDescription`；本机无 Xcode。
- 依赖（2026-11-20 新增）：`record`（录音）、`audioplayers`（朗读播放）、
  `file_picker`、`image_picker`、`path_provider`。
- 架构：`lib/data`（模型/服务/注册表）→ `lib/state`（ChangeNotifier）→
  `lib/ui`（页面/组件）。颜色只走 `core/theme/app_colors.dart` 语义 token。
- 能力与服务位置（追平鸿蒙端）：
  - 设置「工具」：服务商（DeepSeek/百智云）、两套百智云 Key、7 个功能开关、所在地；
  - `services/update_service.dart`：Gitee→GitHub 双源检查更新；
  - `services/apk_update_service.dart` + `android/.../ApkUpdateChannel.kt`：Android 应用内下载
    APK（系统 DownloadManager，后台可继续）→ FileProvider → 系统安装页；进度走 EventChannel；
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
- Android 真机（2026-11-26 起本机可用）：`adb` 在 `D:\tools\scrcpy-win64-v5.0.1\adb.exe`（不在 PATH），
  serial `A7PEUT3407000681`（Honor ANB-AN00 / Android 15）；装包
  `flutter build apk --debug` → `adb install -r -d build\app\outputs\flutter-apk\app-debug.apk`，
  启动 `adb shell am start -n com.example.openchat/com.aishangwuji.openchat.MainActivity`，日志
  `adb logcat -s flutter:*`。该机开着平行空间/分身（user 100/128），`pm list packages` 不带
  `--user 0` 会报 SecurityException；Flutter 语义树默认不上报，`uiautomator dump` 拿不到文字，
  UI 层验证要么用 `integration_test`，要么临时写一个探针入口（`flutter build apk -t lib/xxx.dart`）。
- 验证边界：录音、相册、文件选择、音频播放、生图仍需按 `techdebt/TD-004-*.md` 的真机回归清单实测。
- **应用内更新（2026-11-26 落地，别改回跳浏览器）**：
  - 链路：`services/apk_update_service.dart`（Method/Event 通道）↔
    `android/.../ApkUpdateChannel.kt`；UI 是 `ui/widgets/update_download_sheet.dart`（进度面板）
    ＋ `ui/widgets/update_install_host.dart`（下完自动拉起安装页）。
  - 下载走系统 DownloadManager：落 `getExternalFilesDir(DOWNLOADS)`（应用私有目录，无需存储权限），
    退后台/杀进程都继续；进度是 300ms 轮询 `COLUMN_BYTES_DOWNLOADED_SO_FAR` 推给 Dart。
  - 安装：FileProvider authority `${applicationId}.fileprovider`，只暴露 `Download/`
    （`res/xml/file_paths.xml`）→ `ACTION_VIEW` + APK MIME 交系统 PackageInstaller；
    缺「安装未知应用」权限时返回 need_permission，由 Dart 引导
    `ACTION_MANAGE_UNKNOWN_APP_SOURCES`，不要静默失败。
  - 自动弹安装页只在**前台**（resumed）触发——Android 10+ 不允许后台启动 Activity；
    后台下完等回到应用再补一次。
  - 状态不持久：进程被杀后 Flutter 侧进度丢失（下载仍在跑、通知栏可见），重开需再点检查更新。
  - 必须 https 直链：实测本地 `http://127.0.0.1`（配合 `adb reverse`）在 DownloadManager 里
    直接 failed，真机验证请用真实 release 资产。
  - 签名一致才能覆盖安装：当前 release 回退 debug 签名（无 `android/key.properties`），
    换签名后老用户只能卸载重装。
  - `REQUEST_INSTALL_PACKAGES` 用于自更新不符合 Google Play 政策；本项目侧载分发不受影响，
    将来上架 Play 必须改回商店内更新。
  - 验证手法：临时探针 `lib/dev_update_probe.dart` +
    `flutter build apk --debug -t lib/dev_update_probe.dart`；预授权
    `adb shell appops set com.example.openchat REQUEST_INSTALL_PACKAGES allow`；
    用 `dumpsys activity activities | Select-String topResumedActivity` 确认
    `PackageInstallerActivity` 在前台。探针是临时文件，验证完删掉、不要提交。
- 认知文档：`systemmap/balance-app-mobile.md`；发布缺口：`techdebt/TD-004-*.md`；
  两端差距历史：`techdebt/TD-006-*.md`。