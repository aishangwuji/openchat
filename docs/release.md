# 发布流程（GitHub + Gitee 双源）

应用内「检查更新」读的是 **release**，不是 tag：`tag_name` 作版本号，`body` 作更新说明，
`assets` 里的 `.hap`（鸿蒙）或 `.apk`（Android）作下载直链。因此每次发布必须同时满足：

1. `BalanceApp/AppScope/app.json5` 的 `versionName` 递增（`versionCode` 也要递增，安装器用它比较）；
2. `mobile/pubspec.yaml` 的 `version:` 与 `mobile/lib/core/app_version.dart` 同步递增；
3. 打 `vX.Y.Z` 标签；
4. release 里挂上 `openchat-X.Y.Z.hap` 与 `openchat-X.Y.Z.apk`；
5. GitHub 与 Gitee 两个源都发（应用先查 Gitee、失败再查 GitHub）。

## 1. 改版本号

```powershell
# BalanceApp/AppScope/app.json5
"versionCode": 1000004,
"versionName": "1.0.4",

# mobile/pubspec.yaml
version: 1.0.4+5          # versionName+versionCode

# mobile/lib/core/app_version.dart
const String appVersion = '1.0.4';
```

版本比较是逐段数值比较（`1.0.10 > 1.0.9`），不要用日期式版本号。
`app_version.dart` 是移动端「检查更新」比较的当前版本，漏改会一直提示更新。

> **不要改 Android `applicationId`**：它是安装身份，不是展示名。v1.0.3 曾把
> `com.example.openchat` 改成 `com.aishangwuji.openchat`，v1.0.2 用户升级后会装成
> 第二个应用，旧聊天记录/API Key 全部读不到，v1.0.3 已撤回。要换包名必须先做数据
> 导出/导入迁移（见 `techdebt/TD-015`）；`namespace` 可以单独改。

> 打包前确认本机签名有效（`bundleName` 与证书一致）。签名与安装的机制见
> [signing.md](signing.md)；仓库里不含签名材料，Release 里的 HAP 是作者调试签名，
> 只能装到作者登记过的设备。

## 2. 构建 HAP

```powershell
$env:DEVECO_SDK_HOME = "D:/Program Files/Huawei/DevEco Studio/sdk"
cd BalanceApp
node "D:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js" assembleHap `
  --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon
```

或直接跑 `./scripts/release.ps1`（自动读版本号、构建、拷贝到 `dist/`）。

产物：`BalanceApp/entry/build/default/outputs/default/entry-default-signed.hap`。

> 说明：debug 签名的 HAP 只能在签名时登记过的设备上安装；开源分发的安装包需要读者用
> DevEco 自行签名，或你用自己的发布证书签名后上传。仓库只发源码也可以，HAP 属于便利附件。

### 2.1 构建 Android APK

```powershell
cd mobile
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
flutter build apk --release
Copy-Item build/app/outputs/flutter-apk/app-release.apk ..\dist\openchat-X.Y.Z.apk -Force
```

没有 `mobile/android/key.properties` 时 release 也回退 debug 签名；这种包只能覆盖安装
同样 debug 签名的旧版，换签名后老用户必须卸载重装。

## 3. 提交并打标签

```powershell
git add -A
git commit -m "chore: 发布 v1.0.1"
git tag v1.0.1
git push origin main --tags        # origin = Gitee（本机可直连）
```

GitHub 那边**不要直接 push**：本机直连 `github.com` 会被重置（`api.github.com` 正常，
但 git 走 443 的 `github.com` 不通）。仓库里已放 Actions 工作流
`.github/workflows/mirror-from-gitee.yml`，从 Gitee 拉镜像推回 GitHub：

```powershell
gh workflow run mirror-from-gitee.yml --repo aishangwuji/openchat
gh run list --repo aishangwuji/openchat --limit 1     # 等 success
gh api repos/aishangwuji/openchat/git/ref/tags/v1.0.1  # 确认 tag 已同步
```

不手动触发也可以，工作流每 2 小时跑一次。

## 4. 发 GitHub Release

```powershell
gh release create v1.0.4 "dist/openchat-1.0.4.hap" "dist/openchat-1.0.4.apk" `
  --repo aishangwuji/openchat `
  --title "v1.0.4" `
  --notes-file "dist/release-notes-1.0.4.md"
```

`gh` 走 API 上传资产，实测可用（不受 `github.com` 直连被重置影响）。

`--notes-file`（或 `--notes`）的内容会原样显示在应用的更新弹窗里（应用内截断到 600 字），
建议用简短的「变更」列表，而不是整段提交日志。

## 5. 发 Gitee Release 并挂 HAP/APK

```powershell
gitee release create --repo aishangwuji/openchat --tag v1.0.4 `
  -n "v1.0.4" -b (Get-Content -Raw dist/release-notes-1.0.4.md)
```

Gitee CLI 的 `release create` 没有 `--attach`，附件用 API 补（HAP 与 APK 都要传）：

```powershell
$id  = (gitee api "/repos/aishangwuji/openchat/releases/tags/v1.0.4" | ConvertFrom-Json).id
$tok = (gitee auth token).Trim()
foreach ($f in @("dist/openchat-1.0.4.hap", "dist/openchat-1.0.4.apk")) {
  curl.exe -sS -X POST "https://gitee.com/api/v5/repos/aishangwuji/openchat/releases/$id/attach_files" `
    -F "access_token=$tok" -F "file=@$f"
}
```

## 6. 校验

```powershell
gh release view v1.0.4 --repo aishangwuji/openchat --json tagName,assets
gitee api "/repos/aishangwuji/openchat/releases/latest"
```

再在应用里「设置 → 关于 → 检查更新」确认弹窗能拿到说明与下载链接。

## 双源维护

```powershell
git remote -v
# origin  https://gitee.com/aishangwuji/openchat.git      （可直连，日常 push）
# github  https://github.com/aishangwuji/openchat.git     （仅作参照，不直接 push）

# 每次发布后
git push origin main --tags
gh workflow run mirror-from-gitee.yml --repo aishangwuji/openchat
```

若只想推代码、不发 release，两个动作即可；应用内检查会因为没有新 tag 而静默跳过。

## 常见问题

- **检查更新提示失败**：Gitee/GitHub API 都可能被网络限制；应用静默失败不打扰用户，
  设置页会提示「暂时无法检查更新」。确认 release 是公开的（私有仓库的 API 需要 token）。
- **弹窗里没有下载按钮**：release 没挂 `.hap` 资产时，应用回退到 release 页面链接。
  Gitee release 的 `html_url` 可能为空，此时务必挂 HAP。
- **装了新版还提示更新**：`versionName` 没改，或 release tag 与 `versionName` 不一致。
- **HAP 装了报签名错误**：仓库里发的是作者本机 debug 签名的包，只能装到签名时登记过的设备；
  其他设备需自己用 DevEco 重新签名。


