/*
 * Settings.ets —— 设置页
 *
 * 以温润静奢为全局视觉基调：留白分组、柔和表面与克制的墨金强调。
 * 支持：
 * 1. 语言：中文（简体）/ English 动态切换与持久化；
 * 2. 外观：系统 / 浅色 / 深色 动态切换与持久化；
 * 3. 字体大小：7 档文字大小调节，第 3 档为标准大小，配实时预览；
 * 4. 个性化：思考内容自动折叠 Switch（提示：开启后，思考结束后将自动折叠思考内容）。
 *
 * 遵循 ArkTS 严格模式规范：无 any/unknown，无解构，强类型定义。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { I18nService, AppLanguage, SUPPORTED_LANGUAGES, LanguageItem } from '../services/I18nService';
import { UpdateService, UpdateInfo } from '../services/UpdateService';
import {
  SettingsService, AppearanceMode, KEY_APP_APPEARANCE, KEY_APP_DARK, KEY_FONT_SIZE_LEVEL, KEY_AUTO_COLLAPSE_THINKING,
  KEY_APP_LOCK_ENABLED, KEY_APP_LOCK_AUTH_MODE, AppLockAuthMode, KEY_TTS_VOICE, DEFAULT_TTS_VOICE,
  KEY_FEATURE_TITLE, KEY_FEATURE_FILES, KEY_FEATURE_ASR, KEY_FEATURE_TTS, KEY_FEATURE_IMAGE, KEY_FEATURE_SAFETY,
  KEY_FEATURE_READ_URL,
  KEY_USER_LOCATION,
  KEY_WEB_SEARCH_PROVIDER, WEB_SEARCH_PROVIDER_DEEPSEEK, WEB_SEARCH_PROVIDER_BAIZHI,
  KEY_BAIZHI_IMAGE_READY, KEY_BAIZHI_WEB_READY
} from '../services/SettingsService';
import { AuthService } from '../services/AuthService';
import {
  skinColor, skinList, currentSkinId, findSkin, applySkin, persistSkin, syncDarkMode, SkinDefinition
} from '../services/SkinService';

const DOMAIN = 0x0000;
const TAG = 'Settings';

interface AppearanceOption {
  key: AppearanceMode;
  nameKey: string;
}

const APPEARANCE_OPTIONS: AppearanceOption[] = [
  { key: 'system', nameKey: 'settings_appearance_system' },
  { key: 'light', nameKey: 'settings_appearance_light' },
  { key: 'dark', nameKey: 'settings_appearance_dark' }
];

/** 朗读音色：只有 DeepSeek TTS 的两种音色，值与服务端 voice_id 一致。 */
interface VoiceOption {
  key: string;
  nameKey: string;
  descKey: string;
}

const VOICE_OPTIONS: VoiceOption[] = [
  { key: 'stella', nameKey: 'settings_voice_stella', descKey: 'settings_voice_stella_desc' },
  { key: 'tide', nameKey: 'settings_voice_tide', descKey: 'settings_voice_tide_desc' }
];

/** 应用锁解锁方式：值直接落 Preferences，新增枚举时必须同步 SettingsService.normalizeAuthMode。 */
interface AuthModeOption {
  key: AppLockAuthMode;
  nameKey: string;
  descKey: string;
}

const AUTH_MODE_OPTIONS: AuthModeOption[] = [
  { key: 'any', nameKey: 'settings_app_lock_method_any', descKey: 'settings_app_lock_method_any_desc' },
  { key: 'face', nameKey: 'settings_app_lock_method_face', descKey: 'settings_app_lock_method_face_desc' },
  {
    key: 'fingerprint', nameKey: 'settings_app_lock_method_fingerprint',
    descKey: 'settings_app_lock_method_fingerprint_desc'
  },
  { key: 'password', nameKey: 'settings_app_lock_method_password', descKey: 'settings_app_lock_method_password_desc' }
];

@Entry
@Component
struct Settings {
  /** 皮肤版本号：皮肤或明暗切换时自增（SkinService），驱动本组件按新调色板重绘。 */
  @StorageProp('skin_version') skinVersion: number = 0;
  @StorageProp('app_language') currentLang: string = 'zh-CN';
  @StorageProp(KEY_APP_APPEARANCE) currentAppearance: string = 'system';
  @StorageProp(KEY_FONT_SIZE_LEVEL) currentFontLevel: number = 3;
  @StorageProp(KEY_AUTO_COLLAPSE_THINKING) autoCollapseThinking: boolean = true;
  @StorageProp(KEY_TTS_VOICE) ttsVoice: string = DEFAULT_TTS_VOICE;
  @StorageProp(KEY_APP_LOCK_ENABLED) appLockEnabled: boolean = false;
  @StorageProp(KEY_APP_LOCK_AUTH_MODE) authMode: string = 'any';
  /** 当前版本（运行时读 BundleInfo，和 AppScope 同源）。 */
  @State currentVersion: string = UpdateService.currentVersion();
  @State checkingUpdate: boolean = false;

  // 底部弹框控制
  @State showLanguageSheet: boolean = false;
  @State showAppearanceSheet: boolean = false;
  // 主题风格面板（皮肤切换）
  @State showSkinSheet: boolean = false;
  @State showFontSizeSheet: boolean = false;
  @State showPersonalizeSheet: boolean = false;
  @State showVoiceSheet: boolean = false;
  @State showImageSheet: boolean = false;
  @State showWebKeySheet: boolean = false;
  @State showToolProviderSheet: boolean = false;
  /**
   * 百智云 Key 状态：各模块 Key 互不通用，订阅 SettingsService 写入的 AppStorage 布尔值，
   * 保存/清除后本页与聊天页同时立刻刷新。
   */
  @StorageProp(KEY_BAIZHI_IMAGE_READY) imageHasKey: boolean = false;
  @State imageKeyInput: string = '';
  /** 百智云联网搜索 Key（与生图 Key 分开）。 */
  @StorageProp(KEY_BAIZHI_WEB_READY) webKeyHasKey: boolean = false;
  @State webKeyInput: string = '';
  @StorageProp(KEY_WEB_SEARCH_PROVIDER) webSearchProvider: string = WEB_SEARCH_PROVIDER_DEEPSEEK;
  @StorageProp(KEY_FEATURE_TITLE) featureTitle: boolean = true;
  @StorageProp(KEY_FEATURE_FILES) featureFiles: boolean = true;
  @StorageProp(KEY_FEATURE_ASR) featureAsr: boolean = true;
  @StorageProp(KEY_FEATURE_TTS) featureTts: boolean = true;
  @StorageProp(KEY_FEATURE_IMAGE) featureImage: boolean = true;
  @StorageProp(KEY_FEATURE_SAFETY) featureSafety: boolean = false;
  @StorageProp(KEY_FEATURE_READ_URL) featureReadUrl: boolean = true;
  /** 用户所在地（可留空）：随 latest_reminder 告诉模型。 */
  @StorageProp(KEY_USER_LOCATION) userLocation: string = '';
  @State showLocationSheet: boolean = false;
  @State locationInput: string = '';
  @State showAppLockSheet: boolean = false;

  // 字体大小滑块临时滑动值 (1 ~ 7)
  @State tempFontLevel: number = 3;

  aboutToAppear(): void {
    const uiCtx = this.getUIContext();
    const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
    I18nService.init(hostCtx);
    SettingsService.init(hostCtx);
    this.tempFontLevel = this.currentFontLevel;
  }

  private t(key: string): string {
    const lang: AppLanguage = this.currentLang === 'en-US' ? 'en-US' : 'zh-CN';
    return I18nService.t(key, lang);
  }

  private currentLanguageDisplay(): string {
    let i: number = 0;
    while (i < SUPPORTED_LANGUAGES.length) {
      if (SUPPORTED_LANGUAGES[i].code === this.currentLang) {
        return SUPPORTED_LANGUAGES[i].nativeName;
      }
      i += 1;
    }
    return '中文（简体中文）';
  }

  private currentAppearanceDisplay(): string {
    if (this.currentAppearance === 'light') {
      return this.t('settings_appearance_light');
    }
    if (this.currentAppearance === 'dark') {
      return this.t('settings_appearance_dark');
    }
    return this.t('settings_appearance_system');
  }

  private currentFontSizeDisplay(): string {
    if (this.currentFontLevel === 3) {
      return this.t('settings_font_size_standard');
    }
    return `${this.currentFontLevel} / 7`;
  }

  /** 朗读音色显示名（stella 默认）。 */
  private currentVoiceDisplay(): string {
    return this.ttsVoice === 'tide' ? this.t('settings_voice_tide') : this.t('settings_voice_stella');
  }

  private async selectVoice(key: string): Promise<void> {
    try {
      const uiCtx = this.getUIContext();
      const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
      await SettingsService.setTtsVoice(hostCtx, key);
      this.showVoiceSheet = false;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'selectVoice failed: %{public}s', String(err));
    }
  }

  /** 保存所在地：只影响 latest_reminder，留空 = 不告诉模型所在地。 */
  private async saveUserLocation(): Promise<void> {
    try {
      const uiCtx = this.getUIContext();
      const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
      await SettingsService.setUserLocation(hostCtx, this.locationInput);
      this.showLocationSheet = false;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'saveUserLocation failed: %{public}s', String(err));
    }
  }

  private async selectLanguage(code: AppLanguage): Promise<void> {    try {
      const uiCtx = this.getUIContext();
      const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
      await I18nService.setLanguage(hostCtx, code);
      this.showLanguageSheet = false;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'selectLanguage failed: %{public}s', String(err));
    }
  }

  private async selectAppearance(mode: AppearanceMode): Promise<void> {
    try {
      const uiCtx = this.getUIContext();
      const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
      await SettingsService.setAppearance(hostCtx, mode);
      // 外观模式决定实际明暗，皮肤侧要跟着切深浅调色板（见 SkinService.syncDarkMode）。
      syncDarkMode(AppStorage.get<boolean>(KEY_APP_DARK) ?? false);
      this.showAppearanceSheet = false;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'selectAppearance failed: %{public}s', String(err));
    }
  }

  /**
   * 主题风格选择：先就地生效（skinColor 立即换色 + 版本号触发重绘），再异步落盘。
   * Reason: 落盘失败不该让用户白点一次或看到回滚，所以持久化在生效之后。
   */
  private async selectSkin(id: string): Promise<void> {
    applySkin(id);
    this.showSkinSheet = false;
    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await persistSkin(hostCtx, id);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'selectSkin persist failed: %{public}s', String(err));
    }
  }

  /** 当前主题名（中文/英文界面各自取一套名字）。 */
  private currentSkinDisplay(): string {
    const skin: SkinDefinition = findSkin(currentSkinId());
    return this.currentLang === 'en-US' ? skin.nameEn : skin.name;
  }

  private async applyFontLevel(level: number): Promise<void> {
    try {
      const uiCtx = this.getUIContext();
      const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
      await SettingsService.setFontSizeLevel(hostCtx, level);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'applyFontLevel failed: %{public}s', String(err));
    }
  }

  private async toggleAutoCollapse(enabled: boolean): Promise<void> {
    try {
      const uiCtx = this.getUIContext();
      const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
      await SettingsService.setAutoCollapseThinking(hostCtx, enabled);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'toggleAutoCollapse failed: %{public}s', String(err));
    }
  }

  private async toggleAppLock(enabled: boolean): Promise<void> {
    try {
      const uiCtx = this.getUIContext();
      const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
      await SettingsService.setAppLockEnabled(hostCtx, enabled);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'toggleAppLock failed: %{public}s', String(err));
    }
  }

  /** AppStorage 里的字符串收窄为合法枚举；脏值回落 any（与 SettingsService 读取口径一致）。 */
  private selectedAuthMode(): AppLockAuthMode {
    return SettingsService.isAuthMode(this.authMode) ? this.authMode as AppLockAuthMode : 'any';
  }

  /**
   * 选择解锁方式：先确认设备真正支持（凭据已录入），再落盘。
   * Business Rule: 不允许把应用锁设成设备上不存在的方式，否则下次锁定后无法通过验证。
   */
  private async selectAuthMode(mode: AppLockAuthMode): Promise<void> {
    if (!AuthService.isModeAvailable(mode)) {
      this.toast(this.t('settings_app_lock_method_unavailable'));
      return;
    }
    if (mode === this.selectedAuthMode()) {
      return;
    }
    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await SettingsService.setAppLockAuthMode(hostCtx, mode);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'selectAuthMode failed: %{public}s', String(err));
    }
  }

  private toast(text: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: text });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'showToast failed: %{public}s', String(err));
    }
  }

  private currentAppLockDisplay(): string {
    return this.appLockEnabled ? this.t('settings_app_lock_on') : this.t('settings_app_lock_off');
  }

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'back failed: %{public}s', String(err));
    }
  }

  private openAssets(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/Assets' }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'push Assets failed: %{public}s', String(e));
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'push Assets error: %{public}s', String(err));
    }
  }

  /**
   * 手动检查更新：Gitee → GitHub 双源，发现新版本弹窗给出说明与下载入口。
   * Business Rule: 安装交由系统浏览器（HarmonyOS 不允许应用静默安装 HAP）。
   */
  private async checkUpdate(): Promise<void> {
    if (this.checkingUpdate) {
      return;
    }
    this.checkingUpdate = true;
    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const info: UpdateInfo | null = await UpdateService.check(hostCtx);
      if (info === null) {
        this.getUIContext().showAlertDialog({
          title: this.t('settings_check_update'),
          message: `${this.t('settings_up_to_date')}（v${this.currentVersion}）`
        });
        return;
      }
      const message: string = info.notes.length > 0 ? info.notes : `v${info.version}`;
      this.getUIContext().showAlertDialog({
        title: `${this.t('settings_new_version_title')} v${info.version}`,
        message: message,
        primaryButton: {
          value: this.t('settings_download'),
          action: () => {
            this.openExternal(info.downloadUrl);
          }
        },
        secondaryButton: {
          value: this.t('settings_later'),
          action: () => {
          }
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'check update failed: %{public}s', String(err));
      this.getUIContext().showAlertDialog({
        title: this.t('settings_check_update'),
        message: this.t('settings_check_failed')
      });
    } finally {
      this.checkingUpdate = false;
    }
  }

  private openProjectPage(): void {
    this.openExternal('https://gitee.com/aishangwuji/openchat');
  }

  private async saveImageKey(): Promise<void> {
    const text: string = this.imageKeyInput.trim();
    if (text.length === 0) {
      return;
    }
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await SettingsService.setImageKey(hostCtx, text);
    this.imageKeyInput = '';
    this.showImageSheet = false;
  }

  private async clearImageKey(): Promise<void> {
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await SettingsService.setImageKey(hostCtx, '');
    this.imageKeyInput = '';
    this.showImageSheet = false;
  }

  private openExternal(url: string): void {
    if (url.length === 0) {
      return;
    }
    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      hostCtx.startAbility({
        action: 'ohos.want.action.viewData',
        uri: url,
        entities: ['entity.system.browsable']
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'open external failed: %{public}s', String(err));
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 顶部导航栏
        Row() {
          Text('‹')
            .fontSize(28)
            .fontColor(skinColor('text_primary'))
            .width(42)
            .height(42)
            .textAlign(TextAlign.Center)
            .backgroundColor(skinColor('surface_alt'))
            .borderRadius(21)
            .onClick(() => {
              this.goBack();
            })
          Text(this.t('settings_title'))
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
            .margin({ left: 8 })
          Blank()
        }
        .width('92%')
        .height(58)

        Scroll() {
          Column() {
            // ── 应用 ──
            Text(this.t('settings_section_app'))
              .fontSize(11)
              .letterSpacing(0.4)
              .fontColor(skinColor('text_muted'))
              .width('92%')
              .margin({ top: 22, bottom: 10 })

            Column() {
              this.SettingRow($r('app.media.ic_language'), this.t('settings_language'), this.currentLanguageDisplay(), false, () => {
                this.showLanguageSheet = true;
              })
              this.SettingRow($r('app.media.ic_appearance'), this.t('settings_appearance'), this.currentAppearanceDisplay(), false, () => {
                this.showAppearanceSheet = true;
              })
              this.SettingRow($r('app.media.ic_skin'), this.t('settings_skin'), this.currentSkinDisplay(), false, () => {
                this.showSkinSheet = true;
              })
              this.SettingRow($r('app.media.ic_font'), this.t('settings_font_size'), this.currentFontSizeDisplay(), false, () => {
                this.tempFontLevel = this.currentFontLevel;
                this.showFontSizeSheet = true;
              })
              this.SettingRow($r('app.media.ic_personalize'), this.t('settings_personalize'), '', true, () => {
                this.showPersonalizeSheet = true;
              })
            }
            .width('92%')
            .backgroundColor(skinColor('surface'))
            .borderRadius(20)
            .border({ width: 1, color: skinColor('border_soft') })

            // ── 语音 ──
            Text(this.t('settings_section_voice'))
              .fontSize(11)
              .letterSpacing(0.4)
              .fontColor(skinColor('text_muted'))
              .width('92%')
              .margin({ top: 24, bottom: 10 })

            Column() {
              this.SettingRow($r('app.media.ic_voice'), this.t('settings_tts_voice'), this.currentVoiceDisplay(), true, () => {
                this.showVoiceSheet = true;
              })
            }
            .width('92%')
            .backgroundColor(skinColor('surface'))
            .borderRadius(20)
            .border({ width: 1, color: skinColor('border_soft') })

            // ── 工具 ──
            Text(this.t('settings_section_tools'))
              .fontSize(11)
              .letterSpacing(0.4)
              .fontColor(skinColor('text_muted'))
              .width('92%')
              .margin({ top: 24, bottom: 10 })

            Column() {
              this.SettingRow($r('app.media.ic_globe'), this.t('settings_web_provider'),
                this.webProviderDisplay(), false, () => {
                  this.showToolProviderSheet = true;
                })
              if (this.webSearchProvider === WEB_SEARCH_PROVIDER_BAIZHI) {
                this.SettingRow($r('app.media.ic_attach'), this.t('settings_web_key'),
                  this.webKeyHasKey ? this.t('settings_image_key_on') : this.t('settings_image_key_off'), false, () => {
                    this.showWebKeySheet = true;
                  })
              }
              this.SettingRow($r('app.media.ic_gallery'), this.t('settings_image_key'),
                this.imageHasKey ? this.t('settings_image_key_on') : this.t('settings_image_key_off'), true, () => {
                  this.showImageSheet = true;
                })
              // 用户元信息：所在地（可留空），随 latest_reminder 注入对话。
              this.SettingRow($r('app.media.ic_personalize'), this.t('settings_user_location'),
                this.userLocation.length > 0 ? this.userLocation : this.t('settings_user_location_empty'), true, () => {
                  this.locationInput = this.userLocation;
                  this.showLocationSheet = true;
                })
            }
            .width('92%')
            .backgroundColor(skinColor('surface'))
            .borderRadius(20)
            .border({ width: 1, color: skinColor('border_soft') })

            // 功能开关：默认全开，内容安全默认关闭（开启后有额外审核 token 费用）。
            Column() {
              this.ToggleRow(this.t('settings_feature_title'), this.featureTitle, (v: boolean) => {
                this.toggleFeature(KEY_FEATURE_TITLE, v);
              }, false)
              this.ToggleRow(this.t('settings_feature_files'), this.featureFiles, (v: boolean) => {
                this.toggleFeature(KEY_FEATURE_FILES, v);
              }, false)
              this.ToggleRow(this.t('settings_feature_read_url'), this.featureReadUrl, (v: boolean) => {
                this.toggleFeature(KEY_FEATURE_READ_URL, v);
              }, false)
              this.ToggleRow(this.t('settings_feature_asr'), this.featureAsr, (v: boolean) => {
                this.toggleFeature(KEY_FEATURE_ASR, v);
              }, false)
              this.ToggleRow(this.t('settings_feature_tts'), this.featureTts, (v: boolean) => {
                this.toggleFeature(KEY_FEATURE_TTS, v);
              }, false)
              this.ToggleRow(this.t('settings_feature_image'), this.featureImage, (v: boolean) => {
                this.toggleFeature(KEY_FEATURE_IMAGE, v);
              }, false)
              this.ToggleRow(this.t('settings_feature_safety'), this.featureSafety, (v: boolean) => {
                this.toggleFeature(KEY_FEATURE_SAFETY, v);
              }, true)
            }
            .width('92%')
            .margin({ top: 12 })
            .backgroundColor(skinColor('surface'))
            .borderRadius(20)
            .border({ width: 1, color: skinColor('border_soft') })

            // ── 安全 ──
            Text(this.t('settings_section_security'))
              .fontSize(11)
              .letterSpacing(0.4)
              .fontColor(skinColor('text_muted'))
              .width('92%')
              .margin({ top: 24, bottom: 10 })

            Column() {
              this.SettingRow($r('app.media.ic_lock'), this.t('settings_app_lock'), this.currentAppLockDisplay(), true, () => {
                this.showAppLockSheet = true;
              })
            }
            .width('92%')
            .backgroundColor(skinColor('surface'))
            .borderRadius(20)
            .border({ width: 1, color: skinColor('border_soft') })

            // ── 数据 ──
            Text(this.t('settings_section_data'))
              .fontSize(11)
              .letterSpacing(0.4)
              .fontColor(skinColor('text_muted'))
              .width('92%')
              .margin({ top: 24, bottom: 10 })

            Column() {
              this.SettingRow($r('app.media.ic_assets'), this.t('settings_assets'), this.t('settings_assets_desc'), true, () => {
                this.openAssets();
              })
            }
            .width('92%')
            .backgroundColor(skinColor('surface'))
            .borderRadius(20)
            .border({ width: 1, color: skinColor('border_soft') })

            // ── 关于 ──
            Text(this.t('settings_section_about'))
              .fontSize(11)
              .letterSpacing(0.4)
              .fontColor(skinColor('text_muted'))
              .width('92%')
              .margin({ top: 24, bottom: 10 })

            Column() {
              this.SettingRow($r('app.media.ic_refresh'), this.t('settings_check_update'),
                this.checkingUpdate ? this.t('settings_checking') : `v${this.currentVersion}`, false, () => {
                  this.checkUpdate();
                })
              this.SettingRow($r('app.media.ic_character'), this.t('settings_project_page'), '', true, () => {
                this.openProjectPage();
              })
            }
            .width('92%')
            .backgroundColor(skinColor('surface'))
            .borderRadius(20)
            .border({ width: 1, color: skinColor('border_soft') })

            Text(this.t('settings_version'))
              .fontSize(12)
              .fontColor(skinColor('text_faint'))
              .margin({ top: 30, bottom: 18 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(skinColor('page_bg'))

      // 底部弹框：多语言切换面板
      if (this.showLanguageSheet) {
        this.LanguageSheet()
      }

      // 底部弹框：外观切换面板
      if (this.showAppearanceSheet) {
        this.AppearanceSheet()
      }

      // 底部弹框：主题风格（皮肤）面板
      if (this.showSkinSheet) {
        this.SkinSheet()
      }

      // 底部弹框：字体大小调节面板
      if (this.showFontSizeSheet) {
        this.FontSizeSheet()
      }

      // 底部弹框：个性化面板
      if (this.showPersonalizeSheet) {
        this.PersonalizeSheet()
      }

      // 底部弹框：朗读音色面板
      if (this.showVoiceSheet) {
        this.VoiceSheet()
      }

      // 底部弹框：百智云生图 Key
      if (this.showImageSheet) {
        this.ImageKeySheet()
      }

      // 底部弹框：联网搜索服务商
      if (this.showToolProviderSheet) {
        this.ToolProviderSheet()
      }

      // 底部弹框：百智云搜索 Key
      if (this.showWebKeySheet) {
        this.WebKeySheet()
      }

      // 底部弹框：所在地（用户元信息标记）
      if (this.showLocationSheet) {
        this.LocationSheet()
      }

      // 底部弹框：应用锁面板
      if (this.showAppLockSheet) {
        this.AppLockSheet()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ── 1. 语言切换 Sheet ──
  @Builder
  LanguageSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showLanguageSheet = false;
        })

      Column() {
        Row() {
          Text(this.t('settings_select_language'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showLanguageSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 12 })

        ForEach(SUPPORTED_LANGUAGES, (item: LanguageItem) => {
          Row() {
            Column() {
              Text(item.nativeName)
                .fontSize(15)
                .fontWeight(this.currentLang === item.code ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(this.currentLang === item.code ? skinColor('accent') : skinColor('text_primary'))
              if (item.code !== 'en-US') {
                Text(item.name)
                  .fontSize(12)
                  .fontColor(skinColor('text_muted'))
                  .margin({ top: 2 })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            if (this.currentLang === item.code) {
              Text('✓')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(skinColor('accent'))
            }
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 14, bottom: 14 })
          .border({ width: { bottom: 1 }, color: skinColor('fill') })
          .onClick(() => {
            this.selectLanguage(item.code);
          })
        }, (item: LanguageItem) => item.code)

        Blank().height(24)
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 28, topRight: 28 })
      .border({ width: 1, color: skinColor('border_soft') })
      .shadow({ radius: 24, color: 'rgba(20,18,14,0.14)', offsetX: 0, offsetY: 8 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  // ── 2. 外观切换 Sheet ──
  @Builder
  AppearanceSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showAppearanceSheet = false;
        })

      Column() {
        Row() {
          Text(this.t('settings_appearance_select'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showAppearanceSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 12 })

        ForEach(APPEARANCE_OPTIONS, (opt: AppearanceOption) => {
          Row() {
            Text(this.t(opt.nameKey))
              .fontSize(15)
              .fontWeight(this.currentAppearance === opt.key ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.currentAppearance === opt.key ? skinColor('accent') : skinColor('text_primary'))
              .layoutWeight(1)

            if (this.currentAppearance === opt.key) {
              Text('✓')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(skinColor('accent'))
            }
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 16, bottom: 16 })
          .border({ width: { bottom: 1 }, color: skinColor('fill') })
          .onClick(() => {
            this.selectAppearance(opt.key);
          })
        }, (opt: AppearanceOption) => opt.key)

        Blank().height(24)
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 28, topRight: 28 })
      .border({ width: 1, color: skinColor('border_soft') })
      .shadow({ radius: 24, color: 'rgba(20,18,14,0.14)', offsetX: 0, offsetY: 8 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  // ── 2.5 主题风格（皮肤）Sheet ──
  @Builder
  SkinSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showSkinSheet = false;
        })

      Column() {
        Row() {
          Text(this.t('settings_skin_select'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showSkinSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 12 })

        ForEach(skinList(), (skin: SkinDefinition) => {
          Row() {
            // 预览块：底板 / 卡片 / 主色三根色条，直接取该皮肤的浅色调色板，切换前就能看出气质
            Row() {
              Row()
                .width(9)
                .height(28)
                .backgroundColor(skin.light.get('page_bg'))
                .borderRadius(3)
              Row()
                .width(9)
                .height(28)
                .margin({ left: 3 })
                .backgroundColor(skin.light.get('surface'))
                .borderRadius(3)
              Row()
                .width(9)
                .height(28)
                .margin({ left: 3 })
                .backgroundColor(skin.light.get('accent'))
                .borderRadius(3)
            }
            .height(34)
            .padding({ left: 8, right: 8 })
            .backgroundColor(skinColor('fill'))
            .borderRadius(10)

            Column() {
              Text(this.currentLang === 'en-US' ? skin.nameEn : skin.name)
                .fontSize(15)
                .fontWeight(currentSkinId() === skin.id ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(currentSkinId() === skin.id ? skinColor('accent') : skinColor('text_primary'))
                .width('100%')
              Text(this.currentLang === 'en-US' ? skin.noteEn : skin.note)
                .fontSize(11)
                .fontColor(skinColor('text_muted'))
                .maxLines(2)
                .margin({ top: 3 })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 12 })

            if (currentSkinId() === skin.id) {
              Text('✓')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(skinColor('accent'))
            }
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 12, bottom: 12 })
          .border({ width: { bottom: 1 }, color: skinColor('fill') })
          .onClick(() => {
            this.selectSkin(skin.id);
          })
        }, (skin: SkinDefinition) => skin.id)

        Blank().height(24)
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 28, topRight: 28 })
      .border({ width: 1, color: skinColor('border_soft') })
      .shadow({ radius: 24, color: 'rgba(20,18,14,0.14)', offsetX: 0, offsetY: 8 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  // ── 3. 朗读音色 Sheet ──
  @Builder
  VoiceSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showVoiceSheet = false;
        })

      Column() {
        Row() {
          Text(this.t('settings_voice_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showVoiceSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 8 })

        Text(this.t('settings_voice_hint'))
          .fontSize(12)
          .fontColor(skinColor('text_muted'))
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 8 })

        ForEach(VOICE_OPTIONS, (opt: VoiceOption) => {
          Row() {
            Column() {
              Text(this.t(opt.nameKey))
                .fontSize(15)
                .fontWeight(this.ttsVoice === opt.key ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(this.ttsVoice === opt.key ? skinColor('accent') : skinColor('text_primary'))
              Text(this.t(opt.descKey))
                .fontSize(12)
                .fontColor(skinColor('text_muted'))
                .margin({ top: 3 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            if (this.ttsVoice === opt.key) {
              Text('✓')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(skinColor('accent'))
            }
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 14, bottom: 14 })
          .border({ width: { bottom: 1 }, color: skinColor('fill') })
          .onClick(() => {
            this.selectVoice(opt.key);
          })
        }, (opt: VoiceOption) => opt.key)

        Blank().height(24)
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 28, topRight: 28 })
      .border({ width: 1, color: skinColor('border_soft') })
      .shadow({ radius: 24, color: 'rgba(20,18,14,0.14)', offsetX: 0, offsetY: 8 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  // ── 4. 字体大小调节 Sheet ──
  @Builder
  FontSizeSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showFontSizeSheet = false;
        })

      Column() {
        // 顶部标题
        Row() {
          Text(this.t('settings_font_size_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showFontSizeSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 12 })

        // 预览卡片
        Column() {
          Text(this.t('settings_font_size_preview_title'))
            .fontSize(12)
            .fontColor(skinColor('text_muted'))
            .margin({ bottom: 8 })

          Text(this.t('settings_font_size_preview_sample'))
            .fontSize(15 * SettingsService.getScaleByLevel(this.tempFontLevel))
            .fontColor(skinColor('text_primary'))
            .lineHeight(22 * SettingsService.getScaleByLevel(this.tempFontLevel))
        }
        .width('90%')
        .padding(16)
        .backgroundColor(skinColor('surface_alt'))
        .borderRadius(12)
        .borderWidth(1)
        .borderColor(skinColor('border_card'))
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 10, bottom: 20 })

        // 七档滑块说明与标尺
        Row() {
          Text('A')
            .fontSize(12)
            .fontColor(skinColor('text_secondary'))
          Blank()
          Text(this.tempFontLevel === 3 ? this.t('settings_font_size_standard') : `${this.tempFontLevel} / 7`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(skinColor('accent'))
          Blank()
          Text('A')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_secondary'))
        }
        .width('88%')
        .margin({ bottom: 8 })

        // 7 档离散 Slider
        Slider({
          value: this.tempFontLevel,
          min: 1,
          max: 7,
          step: 1,
          style: SliderStyle.InSet
        })
          .blockColor(skinColor('accent_solid'))
          .trackColor(skinColor('border_card'))
          .selectedColor(skinColor('accent_solid'))
          .showSteps(true)
          .width('90%')
          .onChange((value: number, mode: SliderChangeMode) => {
            const rounded: number = Math.round(value);
            this.tempFontLevel = rounded;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.applyFontLevel(rounded);
            }
          })

        Blank().height(30)
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 28, topRight: 28 })
      .border({ width: 1, color: skinColor('border_soft') })
      .shadow({ radius: 24, color: 'rgba(20,18,14,0.14)', offsetX: 0, offsetY: 8 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  // ── 4. 个性化 Sheet ──
  @Builder
  PersonalizeSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showPersonalizeSheet = false;
        })

      Column() {
        Row() {
          Text(this.t('settings_personalize'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showPersonalizeSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 12 })

        // 思考内容自动折叠卡片
        Column() {
          Row() {
            Column() {
              Text(this.t('settings_auto_collapse_thinking'))
                .fontSize(15)
                .fontColor(skinColor('text_primary'))
                .fontWeight(FontWeight.Medium)
              Text(this.t('settings_auto_collapse_thinking_desc'))
                .fontSize(12)
                .fontColor(skinColor('text_muted'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.autoCollapseThinking })
              .selectedColor(skinColor('accent_solid'))
              .switchPointColor('#FFFFFF')
              .onChange((isOn: boolean) => {
                this.toggleAutoCollapse(isOn);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
        }
        .width('92%')
        .backgroundColor(skinColor('surface_alt'))
        .borderRadius(12)
        .borderWidth(1)
        .borderColor(skinColor('border_card'))
        .margin({ top: 10, bottom: 24 })

        Blank().height(20)
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 28, topRight: 28 })
      .border({ width: 1, color: skinColor('border_soft') })
      .shadow({ radius: 24, color: 'rgba(20,18,14,0.14)', offsetX: 0, offsetY: 8 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  // ── 5. 应用锁 Sheet ──
  @Builder
  AppLockSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showAppLockSheet = false;
        })

      Column() {
        Row() {
          Text(this.t('settings_app_lock_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showAppLockSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 12 })

        // 应用锁卡片
        Column() {
          Row() {
            Column() {
              Text(this.t('settings_app_lock'))
                .fontSize(15)
                .fontColor(skinColor('text_primary'))
                .fontWeight(FontWeight.Medium)
              Text(this.t('settings_app_lock_desc'))
                .fontSize(12)
                .fontColor(skinColor('text_muted'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.appLockEnabled })
              .selectedColor(skinColor('accent_solid'))
              .switchPointColor('#FFFFFF')
              .onChange((isOn: boolean) => {
                this.toggleAppLock(isOn);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
        }
        .width('92%')
        .backgroundColor(skinColor('surface_alt'))
        .borderRadius(12)
        .borderWidth(1)
        .borderColor(skinColor('border_card'))
        .margin({ top: 10, bottom: this.appLockEnabled ? 10 : 24 })

        // 解锁方式：开启应用锁后才需要选；关闭时保留原值，下次开启沿用。
        if (this.appLockEnabled) {
          Column() {
            Text(this.t('settings_app_lock_method'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(skinColor('text_primary'))
            Text(this.t('settings_app_lock_method_hint'))
              .fontSize(11)
              .fontColor(skinColor('text_muted'))
              .margin({ top: 3 })

            ForEach(AUTH_MODE_OPTIONS, (opt: AuthModeOption) => {
              Row() {
                Column() {
                  Text(this.t(opt.nameKey))
                    .fontSize(14)
                    .fontWeight(this.selectedAuthMode() === opt.key ? FontWeight.Medium : FontWeight.Regular)
                    .fontColor(this.selectedAuthMode() === opt.key ?
                      skinColor('accent') : skinColor('text_primary'))
                  Text(this.t(opt.descKey))
                    .fontSize(11)
                    .fontColor(skinColor('text_muted'))
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.selectedAuthMode() === opt.key) {
                  Text('✓')
                    .fontSize(16)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(skinColor('accent'))
                }
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .border({ width: { top: 1 }, color: skinColor('fill') })
              .onClick(() => {
                this.selectAuthMode(opt.key);
              })
            }, (opt: AuthModeOption) => opt.key)
          }
          .width('92%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(skinColor('surface_alt'))
          .borderRadius(12)
          .borderWidth(1)
          .borderColor(skinColor('border_card'))
          .margin({ bottom: 24 })
        }

        Blank().height(20)
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 28, topRight: 28 })
      .border({ width: 1, color: skinColor('border_soft') })
      .shadow({ radius: 24, color: 'rgba(20,18,14,0.14)', offsetX: 0, offsetY: 8 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  // ── 7. 百智云生图 Key Sheet ──
  @Builder
  ImageKeySheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showImageSheet = false;
        })

      Column() {
        Row() {
          Text(this.t('settings_image_key'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showImageSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 8 })

        Text(this.t('settings_image_key_desc'))
          .fontSize(12)
          .fontColor(skinColor('text_secondary'))
          .width('90%')
          .margin({ bottom: 12 })

        TextInput({ placeholder: this.t('settings_image_key_placeholder'), text: this.imageKeyInput })
          .width('90%')
          .type(InputType.Password)
          .height(46)
          .backgroundColor(skinColor('fill'))
          .borderRadius(12)
          .onChange((v: string) => {
            this.imageKeyInput = v;
          })

        Row({ space: 12 }) {
          if (this.imageHasKey) {
            Button(this.t('settings_image_clear'))
              .layoutWeight(1)
              .height(44)
              .backgroundColor(skinColor('fill'))
              .fontColor(skinColor('text_primary'))
              .borderRadius(22)
              .onClick(() => {
                this.clearImageKey();
              })
          }
          Button(this.t('settings_image_save'))
            .layoutWeight(1)
            .height(44)
            .backgroundColor(skinColor('accent_solid'))
            .fontColor(skinColor('accent_contrast'))
            .borderRadius(22)
            .onClick(() => {
              this.saveImageKey();
            })
        }
        .width('90%')
        .margin({ top: 16, bottom: 28 })
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 24, topRight: 24 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

    /** 开关行：标题 + Switch，写回 SettingsService（@StorageProp 驱动页面刷新）。 */
  @Builder
  ToggleRow(title: string, isOn: boolean, onChange: (v: boolean) => void, isLast: boolean) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor(skinColor('text_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(skinColor('accent_solid'))
        .onChange((v: boolean) => {
          onChange(v);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .border({ width: { bottom: isLast ? 0 : 1 }, color: skinColor('border_soft') })
  }

  // ── 8. 联网搜索服务商 Sheet ──
  @Builder
  ToolProviderSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showToolProviderSheet = false;
        })

      Column() {
        Row() {
          Text(this.t('settings_web_provider'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showToolProviderSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 8 })

        Text(this.t('settings_web_provider_desc'))
          .fontSize(12)
          .fontColor(skinColor('text_secondary'))
          .width('90%')
          .margin({ bottom: 12 })

        Column() {
          this.ProviderOption(this.t('settings_web_provider_deepseek'),
            this.t('settings_web_provider_deepseek_desc'),
            this.webSearchProvider === WEB_SEARCH_PROVIDER_DEEPSEEK, () => {
              this.selectWebProvider(WEB_SEARCH_PROVIDER_DEEPSEEK);
            })
          this.ProviderOption(this.t('settings_web_provider_baizhi'),
            this.t('settings_web_provider_baizhi_desc'),
            this.webSearchProvider === WEB_SEARCH_PROVIDER_BAIZHI, () => {
              this.selectWebProvider(WEB_SEARCH_PROVIDER_BAIZHI);
            })
        }
        .width('92%')
        .margin({ bottom: 26 })
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 24, topRight: 24 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ProviderOption(title: string, desc: string, selected: boolean, onTap: () => void) {
    Column() {
      Row() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(skinColor('text_primary'))
        Blank()
        if (selected) {
          Text('✓')
            .fontSize(15)
            .fontColor(skinColor('accent_solid'))
        }
      }
      .width('100%')

      Text(desc)
        .fontSize(12)
        .fontColor(skinColor('text_muted'))
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding(14)
    .margin({ bottom: 8 })
    .backgroundColor(skinColor('fill'))
    .borderRadius(14)
    .onClick(onTap)
  }

  // ── 9. 百智云搜索 Key Sheet ──
  @Builder
  WebKeySheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showWebKeySheet = false;
        })

      Column() {
        Row() {
          Text(this.t('settings_web_key'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showWebKeySheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 8 })

        Text(this.t('settings_web_key_desc'))
          .fontSize(12)
          .fontColor(skinColor('text_secondary'))
          .width('90%')
          .margin({ bottom: 12 })

        TextInput({ placeholder: this.t('settings_web_key_placeholder'), text: this.webKeyInput })
          .width('90%')
          .type(InputType.Password)
          .height(46)
          .backgroundColor(skinColor('fill'))
          .borderRadius(12)
          .onChange((v: string) => {
            this.webKeyInput = v;
          })

        Row({ space: 12 }) {
          if (this.webKeyHasKey) {
            Button(this.t('settings_image_clear'))
              .layoutWeight(1)
              .height(44)
              .backgroundColor(skinColor('fill'))
              .fontColor(skinColor('text_primary'))
              .borderRadius(22)
              .onClick(() => {
                this.clearWebKey();
              })
          }
          Button(this.t('settings_image_save'))
            .layoutWeight(1)
            .height(44)
            .backgroundColor(skinColor('accent_solid'))
            .fontColor(skinColor('accent_contrast'))
            .borderRadius(22)
            .onClick(() => {
              this.saveWebKey();
            })
        }
        .width('90%')
        .margin({ top: 16, bottom: 28 })
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 24, topRight: 24 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  // ── 10. 所在地 Sheet（用户元信息标记） ──
  @Builder
  LocationSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill(skinColor('overlay_scrim'))
        .onClick(() => {
          this.showLocationSheet = false;
        })

      Column() {
        Row() {
          Text(this.t('settings_user_location'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(skinColor('text_muted'))
            .padding(6)
            .onClick(() => {
              this.showLocationSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 8 })

        Text(this.t('settings_user_location_desc'))
          .fontSize(12)
          .fontColor(skinColor('text_secondary'))
          .width('90%')
          .margin({ bottom: 12 })

        TextInput({ placeholder: this.t('settings_user_location_placeholder'), text: this.locationInput })
          .width('90%')
          .height(46)
          .backgroundColor(skinColor('fill'))
          .borderRadius(12)
          .onChange((v: string) => {
            this.locationInput = v;
          })

        Row({ space: 12 }) {
          Button(this.t('settings_image_clear'))
            .layoutWeight(1)
            .height(44)
            .backgroundColor(skinColor('fill'))
            .fontColor(skinColor('text_primary'))
            .borderRadius(22)
            .onClick(() => {
              this.locationInput = '';
            })
          Button(this.t('settings_image_save'))
            .layoutWeight(1)
            .height(44)
            .backgroundColor(skinColor('accent_solid'))
            .fontColor(skinColor('accent_contrast'))
            .borderRadius(22)
            .onClick(() => {
              this.saveUserLocation();
            })
        }
        .width('90%')
        .margin({ top: 16, bottom: 28 })
      }
      .width('100%')
      .backgroundColor(skinColor('surface'))
      .borderRadius({ topLeft: 24, topRight: 24 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.move(TransitionEdge.BOTTOM),
        TransitionEffect.move(TransitionEdge.BOTTOM)
      ))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SettingRow(icon: Resource, title: string, value: string, isLast: boolean, onTap: () => void) {
    Row() {
      Row() {
        Image(icon)
          .width(17)
          .height(17)
        }
      .width(36)
      .height(36)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(skinColor('icon_tile'))
      .border({ width: 1, color: skinColor('accent_outline') })
      .borderRadius(12)
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(skinColor('text_primary'))
        .margin({ left: 14 })
        .layoutWeight(1)
      if (value.length > 0) {
        Text(value)
          .fontSize(12)
          .fontColor(skinColor('text_muted'))
          .margin({ right: 8 })
      }
      Text('›')
        .fontSize(20)
        .fontColor(skinColor('icon_muted'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .border({ width: { bottom: isLast ? 0 : 1 }, color: skinColor('border_soft') })
    .onClick(onTap)
  }
  /** 功能开关：写 SettingsService（AppStorage + Preferences），页面通过 @StorageProp 即时生效。 */
  private async toggleFeature(key: string, enabled: boolean): Promise<void> {
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await SettingsService.setFeature(hostCtx, key, enabled);
  }

  /** 联网搜索来源：DeepSeek 服务端工具 / 百智云 OpenAPI。 */
  private async selectWebProvider(provider: string): Promise<void> {
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await SettingsService.setWebSearchProvider(hostCtx, provider);
    this.showToolProviderSheet = false;
  }

  private webProviderDisplay(): string {
    return this.webSearchProvider === WEB_SEARCH_PROVIDER_BAIZHI
      ? this.t('settings_web_provider_baizhi') : this.t('settings_web_provider_deepseek');
  }

  private async saveWebKey(): Promise<void> {
    const text: string = this.webKeyInput.trim();
    if (text.length === 0) {
      return;
    }
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await SettingsService.setBaizhiWebKey(hostCtx, text);
    this.webKeyInput = '';
    this.showWebKeySheet = false;
  }

  private async clearWebKey(): Promise<void> {
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await SettingsService.setBaizhiWebKey(hostCtx, '');
    this.webKeyInput = '';
    this.showWebKeySheet = false;
  }
}