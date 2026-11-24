# openchat

一个鸿蒙（HarmonyOS / ArkTS）小应用，两个目标合在一个壳里：

1. **余额监控**：统一查看各家大模型 / 云服务的账户余额（DeepSeek、Kimi、小米 MiMo 三家 Bearer 厂商，外加百智云积分——Cookie 登录态，附签到跳转）。
2. **对话客户端**：贴近 DeepSeek 官方 App 的聊天体验——联网搜索、正文引用角标、来源胶囊、文件解析（PDF/Office/图片）、图片视觉输入、语音输入与朗读。

仓库：GitHub [aishangwuji/openchat](https://github.com/aishangwuji/openchat) ·
Gitee [aishangwuji/openchat](https://gitee.com/aishangwuji/openchat)。
Gitee 为主干（`origin`），GitHub 由 Actions 自动镜像（`.github/workflows/mirror-from-gitee.yml`）。

> 源码开源，但**不包含签名材料**。鸿蒙应用必须签名才能安装，签名与开发者账号绑定，
> 每人用自己的账号生成——步骤在下面和 [docs/signing.md](docs/signing.md)。

> **移动端说明**：mobile/（Flutter，Android/iOS）已按 2026-11-20 追平鸿蒙端主要能力：
> 应用身份（com.example.openchat）、检查更新、设置「工具」分组与开关、联网搜索
> （DeepSeek 服务端 + 百智云）、引用角标/来源胶囊、文件解析与图片视觉、语音输入/朗读、
> 生图、内容安全；2026-11-23 补齐服务端会话标题、阅读链接与 `latest_reminder`。
> 两端本地存储独立（Key 需各自配置）。仍未对齐：蓝白配色之外的聊天版式微调、
> 分享/导出等长尾差异，见 [techdebt/TD-006](techdebt/TD-006-mobile-web-search-parity.md)。
## 特性

- **资产**：密钥只存本机 Preferences；余额自动刷新，失败保留上次结果。百智云按「积分」展示
  可用/临时/永久/冻结，签到按钮跳浏览器完成人机验证（应用不代签）。
- **对话**：多服务商 / 多模型、流式输出与思考过程、Markdown + 代码高亮、消息分支（编辑/重新生成）、会话自动标题。
- **联网搜索**：DeepSeek 服务端 `deepseek_web_search` 工具，SSE 解析来源，正文注入引用角标，来源可点开。
- **阅读链接**：`deepseek_read_url` 让模型读用户消息里的 URL；网页正文加密在 `signature` 里，
  随消息持久化并在后续轮次原样回传。
- **用户元信息**：每轮注入 `latest_reminder`（日期 / 星期 / 所在地 / 语言），模型知道「今天几号」。
- **文件与图片**：Files API 上传（`user_data` / `text_recognition` 分流），图片走视觉通道，附件随消息持久化。
- **语音**：按住说话录音 → `/v1/tools/asr` 转写回填；回答可朗读（`/v1/tools/tts`，本地音频缓存）。
- **外观**：浅色 / 深色 / 跟随系统，7 档字号，中英双语。
- **安全**：应用锁（锁屏密码 / 指纹 / 人脸），切后台即锁定。

## 快速开始：编译并装到自己的手机

### 0. 环境

- DevEco Studio 6.x，HarmonyOS SDK **6.1.1(24)**
- Node 18+（DevEco 自带）
- 一台开了**开发者模式 + USB 调试**的鸿蒙手机，数据线

### 1. 生成签名（关键一步，只需做一次）

1. DevEco Studio 打开本仓库的 `BalanceApp/` 目录；
2. 菜单 *File → Project Structure → Signing Configs*；
3. 勾选 **Automatically generate signature**，登录华为开发者账号（免费注册）；
4. 手机连上电脑，DevEco 会自动登记设备 UDID、申请调试证书，并把配置写回
   `BalanceApp/build-profile.json5`。

> 这一步生成的 `signingConfigs` 里含本机证书路径与密钥库口令，**不要提交**。
> 建议执行一次 `git update-index --skip-worktree BalanceApp/build-profile.json5`，之后本机改动不会出现在 `git status` 里。

### 2. 编译

```powershell
$env:DEVECO_SDK_HOME = "D:/Program Files/Huawei/DevEco Studio/sdk"
cd BalanceApp
node "D:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js" assembleHap `
  --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon
```

产物：`BalanceApp/entry/build/default/outputs/default/entry-default-signed.hap`
（没做第 1 步的话，构建会在 `SignHap` 报 `bundleName ... does not match`）。

### 3. 安装到手机

```powershell
hdc -t <serial> install -r entry-default-signed.hap
hdc -t <serial> shell aa start -a EntryAbility -b com.example.openchat
```

`<serial>` 用 `hdc list targets` 查；`hdc` 在
`DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe`。

也可以直接在 DevEco 里点 Run，效果一样。

## 为什么别人装不上 Release 里的 HAP

调试签名的 profile 里只登记了**作者自己的设备 UDID**，换台手机装会报
`9568320 signature verify failed`。所以：

- 仓库里不包含 `.p12`（私钥）/ `.p7b`（profile）/ `.cer`（证书），也**不会**公开；
- 别人要用，要么按上面的步骤自己签名，要么等作者上架 AppGallery（唯一能给普通用户分发的途径）；
- 完整的机制、报错排查与升级规则见 [docs/signing.md](docs/signing.md)。

## 更新机制

应用内自带更新检查，更新源就是**本仓库的 Release**（双源，Gitee 优先、GitHub 兜底）：

- 入口：设置 → 关于 → 检查更新；启动时也会静默检查一次（12 小时节流）。
- 逻辑：`UpdateService` 运行时读 `BundleInfo.versionName`，与 release 的 `tag_name` 做逐段数值比较；
  发现新版弹窗展示 release 说明，「去下载」打开 HAP 直链（没有资产则回退 release 页面）。
- 版本号在 `BalanceApp/AppScope/app.json5`（`versionName` / `versionCode` 同步递增）。

### 发一个版本（维护者）

```powershell
# 1. 改版本号（两个字段都要）
#    BalanceApp/AppScope/app.json5
# 2. 构建并收集产物
pwsh ./scripts/release.ps1
# 3. 提交、打 tag、推到 Gitee（主干）
git add -A; git commit -m "chore: 发布 v1.0.1"; git tag v1.0.1
git push origin main --tags
# 4. 让 GitHub 跟上（或等每 2 小时的定时任务）
gh workflow run mirror-from-gitee.yml --repo aishangwuji/openchat
# 5. 两边各发一个 release，挂上 dist/openchat-<ver>.hap
gh release create v1.0.1 "dist/openchat-1.0.1.hap" --repo aishangwuji/openchat --title "v1.0.1" --notes "变更说明"
gitee release create -R aishangwuji/openchat --tag v1.0.1 -n "v1.0.1" -b "变更说明"
#    Gitee CLI 没有 --attach，附件用 attach_files API 补（见 docs/release.md）
```

应用的更新弹窗展示的就是 release 的说明正文，建议写简短的「变更」列表。
细节与校验步骤见 [docs/release.md](docs/release.md)。

## 目录

```
BalanceApp/            鸿蒙应用（entry 模块）
  entry/src/main/ets/
    pages/             页面（对话、设置、资产、角色…）
    services/          业务服务（ChatService、WebSearchService、FileUploadService、VoiceRecorder、AsrService、UpdateService…）
    components/        UI 组件（Markdown 渲染、能力胶囊…）
    models/            数据结构（ChatMessage / ChatSession / SearchSource…）
mobile/                Flutter 跨端（Android / iOS）
systemmap/             模块职责与设计决策（改动前先看）
techdebt/              已知技术债
docs/                  设计稿、发布与签名说明
scripts/               发布辅助脚本
```

## 架构概览

三层，依赖方向单向向下：

```
pages/    ChatView / Settings / Assets / Index     ← ArkUI 声明式页面
  ↓
services/ ChatService / WebSearchService / FileUploadService /
          VoiceRecorder / AsrService / TtsService / UpdateService /
          ChatStorageService / SettingsService / BalanceService
  ↓
models/ + ProviderRegistry（纯数据：厂商定义、数据结构）
```

### 对话数据流

```
TextArea/语音 → ChatView.sendMessage()
  → ChatService.buildApiMessages()（历史 + 系统提示 + 附件 content 数组）
  → POST /chat/completions（stream:true）
  → SSE 逐块回调 onDelta / onReasoning / onSearch / onCitations / onTitle
  → ChatView 写入 ChatMessage 并驱动 Markdown 增量渲染
  → 结束后 ChatStorageService.saveSessions() 落 Preferences
```

- 消息是**树**（`parentId` / `childIds` / `activeChildId`），编辑与重新生成生成兄弟分支，界面只渲染激活路径。
- 联网搜索走服务端工具（`tools:[{type:'deepseek_web_search'}]`），来源随最后一个 chunk 的
  `delta.annotations` 下发，本地持久化在 `message.sources`。
- 附件/图片：先传 Files API 拿 `file_id`，用户消息的 `content` 变成块数组，历史轮次继续用 `file_id` 回放。

### 余额数据流

```
Assets 页面 → BalanceService → ProviderRegistry 取 endpoint/字段映射
  → 按 balanceType 分支：Bearer（Authorization 头）/ CookieSession（Cookie + 浏览器 UA）
  → GET 余额接口 → 通用解析（含积分明细）→ 更新卡片（失败保留上次结果）
```

百智云用 Cookie 引擎：接口金额单位是「分」，除以 100 后按积分展示（币种占位符 `CREDITS`，
不与人民币相加）；签到现在浏览器里手动过验证码，应用只提供 `https://baizhi.cloud/console/apps`
的跳转入口。Cookie 获取方式：浏览器登录 baizhi.cloud → 开发者工具 Network → 复制任一请求的
`Cookie` 请求头（必须含 `baizhi_session`），整行粘进「设置 百智云 的Cookie」弹窗即可。

### 本地存储

| 数据 | 位置 | 说明 |
|---|---|---|
| 会话、角色卡 | Preferences `chat_sessions` 等 | JSON 明文 |
| 各厂商 API Key / 百智云 Cookie | Preferences `key_<providerId>` | 明文，见 TD-001 / TD-009 |
| 外观/字号/语音/应用锁 | Preferences 同名键 | 部分同步到 AppStorage |
| TTS 音频 | `cacheDir/tts_cache` | FNV-1a 键，16 文件/40MB 上限 |
| 录音、上传副本 | `cacheDir` | 用完即删 |

## 关键模块

| 文件 | 职责 |
|---|---|
| `pages/ChatView.ets` | 对话页：消息树渲染、流式输出、联网搜索 UI、附件/语音入口、回答操作条 |
| `services/ChatService.ets` | 请求组装（系统提示、历史投影、附件 content 块）、SSE 解析、工具事件 |
| `services/WebSearchService.ets` | 工具声明、搜索事件解析、来源去重、引用角标注入 |
| `services/FileUploadService.ets` | 文件选择（拍照/相册/文件）、Files API 上传、purpose 分流 |
| `services/VoiceRecorder.ets` | 16k 单声道录音 → PCM 落盘 → 封装 WAV（120 秒上限） |
| `services/AsrService.ets` | `/v1/tools/asr` 转写，失败清理临时音频 |
| `services/TtsService.ets` | `/v1/tools/tts` 朗读 + 本地音频缓存 |
| `services/UpdateService.ets` | 版本比较、Gitee/GitHub 双源 release 检查、静默节流 |
| `services/ChatStorageService.ets` | 会话/角色卡持久化与边界校验 |
| `services/ProviderRegistry.ets` | 各厂商端点、字段路径、换算因子、凭证形态（加厂商只改这里 + 图标） |
| `services/BalanceService.ets` | 余额查询引擎：Bearer / CookieSession 两条通道 + 通用解析（积分明细） |

## 关键设计决策

- **Gitee 为主干、GitHub 自动镜像**：本机直连 `github.com` 的 git 被重置（`api.github.com` 正常），
  所以日常 push Gitee，GitHub 由 `.github/workflows/mirror-from-gitee.yml` 拉取。
- **签名不入库**：`.p12` 含私钥、`.p7b` 绑定 bundleName 与设备列表，公开等于身份被冒用。
  `build-profile.json5` 的 `signingConfigs` 留空，每人本地生成（`docs/signing.md`）。
- **Files API 的 purpose 分流**：文本/表格/电子书走 `user_data`（不解析不计费）；
  PDF/Office 走 `text_recognition`（只取文字）。**图片必须走 `user_data`** 才能被模型「看见」——
  用 `text_recognition` 会被 OCR 成文字（实测同一张图只答出图里的数字）。
- **语音 WAV 先落 PCM 再封装**：早先「先占 44 字节头、停止时按 offset 回填」在真机被服务端判 400，
  改为录完 pcm 后新建 wav、写头再分块拷贝，不依赖 seek 语义。
- **更新走 Release**：`tag_name` 即版本号、`body` 即更新说明、`assets` 里的 `.hap` 即下载直链；
  Gitee 优先、GitHub 兜底；静默检查 12 小时节流。
- **消息树而非线性列表**：编辑/重新生成保留旧分支，用户可以来回切换，历史不丢。
- **已移除上下文净化（TopicGate/Jev）**：判定收益不抵维护成本，且三套配置（开关/阈值/渠道）负担过重；
  若以后要压缩上下文，优先「滚动摘要」而不是逐句判定。

## 开发约定

- **ArkTS 严格模式**：禁 `any/unknown`、禁解构、禁止在 `@Builder` 里写非 UI 语句、
  `catch` 到的值要 `new Error(String(err))` 再抛；`@State` 改数组元素内部字段必须重建引用。
- **提交纪律**：一个提交只做一件事（功能/样式/文档/顺带修复分开）；提交信息写「为什么」。
- **认知沉淀**：改动涉及模块职责或设计取舍时更新 `systemmap/`，新增已知缺口写 `techdebt/`。
- **安全检查**：提交前扫 `sk-` / `gho_` / `AKIA` / 私钥头；API Key 只走 `maskKey` 日志。
- **不要直接 push GitHub**：本机网络到 `github.com` 的 git 会被重置，走 Gitee + 镜像。

## 给 AI Agent 的说明

如果你是被要求「基于这个仓库做事」的 agent，按下面顺序读，再动手：

1. **本文件**（构建/签名/发版/架构的入口）；
2. [`AGENTS.md`](AGENTS.md)（本机工具链、ArkTS 坑位、仓库约定，**先读再写代码**）；
3. `systemmap/`（模块职责与历史决策，按标题检索，不要全文读）；
4. `techdebt/`（已知缺口，别把债务当需求）；
5. 发版相关：`docs/release.md`（双源发布）、`docs/signing.md`（签名与安装）。

动手时的硬约束：

- **不要**提交任何签名材料、密钥、`.env`；`BalanceApp/build-profile.json5` 保持无 `signingConfigs`；
- **不要**直接 `git push` 到 GitHub，也不要 force-push 主干；推 Gitee 后触发镜像；
- 改代码前先跑通构建：
  ```
  $env:DEVECO_SDK_HOME="D:/Program Files/Huawei/DevEco Studio/sdk"
  cd BalanceApp
  node "<DevEco>/tools/hvigor/bin/hvigorw.js" assembleHap --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon
  ```
- 真机验证用 `hdc`（安装、`aa start`、`hilog -x -t app -D 0x0000` 看日志），不要靠猜；
- 发版必须人工确认：改版本号 → 构建 → 打 tag → 双源 release，不要把未验证的包推给用户。

## 数据与安全

- API Key / 百智云 Cookie 存本机 Preferences（`key_<providerId>`），不上传；日志统一掩码
  （Key 用 `maskKey`，Cookie 只记长度）。
- 会话、角色卡以 JSON 存本机 Preferences，**是明文**（见 `techdebt/TD-003`）。
- 应用锁只做本机门禁，不替代系统级加密。
- 仓库全历史不包含任何密钥；提交前会扫 `sk-` / `gho_` / 私钥头。

## 许可证

MIT，见 [LICENSE](LICENSE)。
