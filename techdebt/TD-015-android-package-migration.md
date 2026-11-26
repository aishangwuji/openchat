# TD-015 Android applicationId 迁移（com.example.openchat → 品牌包名）

- 状态：待处理（v1.0.4 已恢复旧 applicationId，事故已止血）
- 影响范围：`mobile/android/app/build.gradle.kts`、`mobile/android/app/src/main/AndroidManifest.xml`、
  `mobile/lib/data/services/key_store.dart`、`chat_storage_service.dart`
- 首次登记：2026-11-26

## 事故

- v1.0.2 的 Android `applicationId` 是 `com.example.openchat`；
- `807a1bc`（v1.0.2 之后）把 `applicationId` 改成 `com.aishangwuji.openchat`，v1.0.3 沿用了新包名；
- Android 按 `applicationId` 识别应用，v1.0.2 用户安装 v1.0.3 会装成第二个应用：
  新包读不到旧包的 SharedPreferences / EncryptedSharedPreferences / Keystore，
  表现为聊天历史空白、API Key 与设置全部丢失；
- 两版签名相同（Android Debug 证书），安装器不会报签名冲突，问题更隐蔽；
- HAP 的 `bundleName` 一直是 `com.example.openchat`，鸿蒙端不受影响；
- v1.0.3 已标记为 pre-release 并加“请勿安装”说明，v1.0.4 恢复旧 `applicationId`。

## 现状

- `applicationId = com.example.openchat`（安装身份，v1.0.4 起冻结）；
- `namespace = com.aishangwuji.openchat`（R 类与 manifest 包名，可与 applicationId 不同）；
- MainActivity 类仍在 `com.aishangwuji.openchat` 包下，启动组件为
  `com.example.openchat/com.aishangwuji.openchat.MainActivity`。

## 迁移方案（未做）

要换品牌包名又保留本地数据，必须先把数据搬出旧包，不能直接改 `applicationId`：

1. 在旧包版本里加“导出全部会话与设置”（JSON，含 Key 的明文需用户确认或改为重新输入）；
2. 新包首次启动检测到无数据时，引导用户选择导出的 JSON 导入；
3. 导入完成后再发布切换 `applicationId` 的版本；
4. 或使用 `sharedUserId`/ContentProvider 做跨包读取，但 `sharedUserId` 已废弃且需要旧包配合，
   不适合已经发布的 v1.0.2。

## 验证

- v1.0.4 APK：`aapt dump badging` 为 `com.example.openchat`、versionCode 5；
- 真机先装 v1.0.2（versionCode 3）再 `adb install -r` v1.0.4：`firstInstallTime` 不变、
  `dataDir=/data/user/0/com.example.openchat` 不变，确认是原地升级而非新装。
