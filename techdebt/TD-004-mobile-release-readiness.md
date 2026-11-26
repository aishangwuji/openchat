# TD-004 移动端发布准备缺口（Android / iOS）

- 状态：待处理
- 影响范围：`mobile/`（Flutter 跨平台端）
- 首次登记：2026-10-23

## 现象 / 缺口

1. **Android release 尚未生成正式 keystore**：`android/app/build.gradle.kts` 已支持
   读取 `android/key.properties` 的 release 签名（缺失时回退 debug）。上架前仍需用
   `keytool` 生成 keystore、填好 `key.properties`，再执行 `flutter build appbundle --release`。
2. **iOS 未编译验证**：开发机为 Windows，没有 Xcode。iOS target、bundle id
   `com.example.balanceapp`、`NSFaceIDUsageDescription` 已配置，但仍需在
   macOS/CI 上执行 `flutter build ios --release --no-codesign` 与真机回归。
3. **运行时验证未完成**：2026-11-26 起本机可连 Android 15 真机（Honor ANB-AN00，
   serial `A7PEUT3407000681`），但真实 SSE、文件解析、语音/朗读、拒答形态仍需用户提供
   API Key 后逐项回归；AVD 的 `system.img` 仍缺失。当前只验证到
   `flutter analyze`、`flutter test`、`flutter build apk --debug`。
4. **应用图标仍是 Flutter 默认图标**：Android mipmap 与 iOS AppIcon 未替换为
   品牌图标；鸿蒙端已有 `startIcon.png`，可直接派生多尺寸资源。
5. **商店材料缺失**：隐私政策、应用截图、应用描述、内容分级、签名证书指纹
   均未准备。
6. **多语言仅覆盖设置页**：`chat` / `assets` 仍为中文硬编码，与鸿蒙端现状一致。
   若要面向海外商店，需要把全部 UI 文案迁入资源文件。
7. **保密会话未加密**：消息正文仍以明文 JSON 存在 `SharedPreferences`；
   `isPrivate` 仅做 UI 门禁（与鸿蒙 `TD-003` 同源）。API Key 已升级到
   Keychain/Keystore，但会话正文尚未加密。
8. **应用锁关闭路径无二次认证**：开启/关闭应用锁均直接改设置；鸿蒙端同样如此。
   若要防「拿到已解锁设备后关闭锁」，应在关闭前要求一次身份认证。
9. **应用标识仍是占位值**（2026-11-20 部分解决）：Android `applicationId` 与 iOS bundle id
   已统一改为 `com.example.openchat`（含 `MainActivity.kt` 包路径、RunnerTests 标识），
   `com.example` 仍是占位前缀，上架前必须换成自有域名反写并重新签名。
10. **新增原生插件未做真机打包验证**：`record`（录音）、`audioplayers`（朗读播放）、
   `file_picker`、`image_picker`、`path_provider` 是 2026-11-20 新引入的插件；
   本轮只通过 `flutter analyze` 与 `flutter test`，`flutter build apk --debug` 因首次
   Gradle 依赖下载停滞未跑完，插件打包、Manifest 合并与权限弹窗都未实测。
11. **iOS 麦克风权限文案**：已补 `NSMicrophoneUsageDescription`，但 iOS 构建需
   macOS/CI，未验证实际弹窗与录音。

## 处置建议

- 上架前按 1→3→4→5 顺序补齐；2 需要 macOS 环境或 CI runner。
- 7 可作为后续安全迭代：为 `isPrivate` 会话引入本地加密（例如
  `cryptography` + Keychain 密钥），并迁移旧数据。
- 8 属于产品决策，若保持与鸿蒙一致可暂不处理，但应在发布说明中标注。

## 真机回归清单（2026-11-20 新增能力，待逐条打勾）

以下功能只有静态验证，需在 Android 真机 / iOS 真机（或可用模拟器）上逐项确认：

1. 设置 > 工具：联网搜索服务商切换、两套百智云 Key 保存/清除（重启后仍在）；
2. 联网搜索：DeepSeek 模式看到「正在联网搜索…」与来源胶囊；百智云模式填 Key 后
   来源胶囊出现，未填 Key 时降级为普通回答；
3. 引用角标：正文 `[1]` 点击能跳到对应来源；
4. 文件解析：选 PDF/Office 上传成功、发送后模型能引用内容；不支持格式有提示；
5. 图片视觉：相册/拍照上传后模型能描述画面（`user_data` 路径，不是 OCR）；
6. 语音输入：首次弹麦克风权限、录音波形/状态、停止后自动转写进输入框；
7. 朗读：点击后能出声、播放中可停止、切换 Stella/Tide 生效、重复朗读命中缓存；
8. 生图：`generate_image` 被调用后显示「正在生成图片…」，1~5 分钟内出图，
   失败有可读原因，图片过期后显示占位；
9. 内容安全：开启后触发拒答时内容被清空并提示；
10. 检查更新：设置 > 关于 > 检查更新能拿到最新 release 并跳转下载；
11. 模型锁定：DeepSeek 选 `deepseek-v4-pro` 且联网/文件等开关开启时发送，应自动切回
    `deepseek-flash` 并显示提示；
12. 纯附件：只上传文件/图片、不输入文字也能发送，模型能基于文件作答；
13. 生成中断：流式中断或末块 error 时，气泡显示错误而不是半截回答当成功；
14. 读链接失败：`url_not_allowed` / 不可达链接应出现「链接读取失败（code）」提示。
