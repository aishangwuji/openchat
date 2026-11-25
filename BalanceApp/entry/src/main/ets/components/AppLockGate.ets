/*
 * AppLockGate.ets
 *
 * 应用锁覆盖层：应用锁开启后，从后台回到前台（或冷启动）时全屏遮挡内容，
 * 必须通过用户所选方式（锁屏密码 / 指纹 / 人脸，或系统自选）后才恢复访问。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { AuthService } from '../services/AuthService';
import {
  AppLockAuthMode, SettingsService, KEY_APP_LOCK_AUTH_MODE, KEY_APP_LOCKED
} from '../services/SettingsService';
import { skinColor } from '../services/SkinService';

const DOMAIN = 0x0000;
const TAG = 'AppLockGate';

@Component
export struct AppLockGate {
  /** 皮肤版本号：皮肤或明暗切换时自增（SkinService），驱动本组件按新调色板重绘。 */
  @StorageProp('skin_version') skinVersion: number = 0;
  @StorageProp(KEY_APP_LOCKED) @Watch('onLockedChanged') locked: boolean = false;
  @StorageProp(KEY_APP_LOCK_AUTH_MODE) authMode: string = 'any';
  @State authenticating: boolean = false;
  /** 所选方式不可用时已回退系统自选，锁定页据此改文案，避免用户以为还是人脸/指纹。 */
  @State fallbackNotice: boolean = false;
  private autoStarted: boolean = false;
  private pendingTimer: number = -1;
  private authSession: number = 0;

  aboutToAppear(): void {
    if (this.locked) {
      this.scheduleUnlock();
    }
  }

  aboutToDisappear(): void {
    this.authSession += 1;
    if (this.pendingTimer >= 0) {
      clearTimeout(this.pendingTimer);
      this.pendingTimer = -1;
    }
  }

  onLockedChanged(): void {
    if (this.locked) {
      this.fallbackNotice = false;
      this.scheduleUnlock();
    } else {
      this.authSession += 1;
      this.authenticating = false;
    }
  }

  /** 把 AppStorage 里的字符串收窄成合法枚举（历史值/脏值回落 any）。 */
  private requestedMode(): AppLockAuthMode {
    return SettingsService.isAuthMode(this.authMode) ? this.authMode as AppLockAuthMode : 'any';
  }

  /** 锁定页说明文案：跟随所选方式。 */
  private modeHint(): string {
    if (this.fallbackNotice) {
      return '所选验证方式不可用，已改用系统验证';
    }
    const mode: AppLockAuthMode = this.requestedMode();
    if (mode === 'face') {
      return '验证人脸识别后继续';
    }
    if (mode === 'fingerprint') {
      return '验证指纹后继续';
    }
    if (mode === 'password') {
      return '验证锁屏密码后继续';
    }
    return '验证锁屏密码、指纹或人脸识别后继续';
  }

  /** 解锁按钮文案：让用户点之前就知道会拉起哪种验证。 */
  private buttonLabel(): string {
    if (this.authenticating) {
      return '正在验证…';
    }
    const mode: AppLockAuthMode = this.requestedMode();
    if (this.fallbackNotice) {
      return '解锁';
    }
    if (mode === 'face') {
      return '人脸解锁';
    }
    if (mode === 'fingerprint') {
      return '指纹解锁';
    }
    if (mode === 'password') {
      return '输入密码解锁';
    }
    return '解锁';
  }

  /** 等首帧渲染后再拉起系统认证，避免页面尚未挂载时弹窗被系统回收。 */
  private scheduleUnlock(): void {
    if (this.autoStarted) {
      return;
    }
    this.autoStarted = true;
    this.pendingTimer = setTimeout(() => {
      this.pendingTimer = -1;
      this.autoStarted = false;
      this.requestUnlock();
    }, 300);
  }

  private async requestUnlock(): Promise<void> {
    if (!this.locked || this.authenticating) {
      return;
    }
    const session: number = ++this.authSession;
    const requested: AppLockAuthMode = this.requestedMode();
    const effective: AppLockAuthMode = AuthService.effectiveMode(requested);
    if (effective !== requested) {
      this.fallbackNotice = true;
      hilog.warn(DOMAIN, TAG, 'auth mode fallback: %{public}s -> %{public}s', requested, effective);
    }
    this.authenticating = true;
    const ok: boolean = await AuthService.authenticate('解锁 openchat', effective);
    if (session !== this.authSession) {
      return;
    }
    this.authenticating = false;
    if (ok) {
      AppStorage.setOrCreate<boolean>(KEY_APP_LOCKED, false);
    } else if (this.locked) {
      this.toast('身份验证未通过，请重试');
    }
  }

  private toast(text: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: text });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'showToast failed: %{public}s', String(err));
    }
  }

  build() {
    if (this.locked) {
      Column() {
        Blank()
        Column() {
          Row() {
            Image($r('app.media.ic_lock'))
              .width(30)
              .height(30)
          }
          .width(72)
          .height(72)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .backgroundColor(skinColor('icon_tile'))
          .borderRadius(36)
          .border({ width: 1, color: skinColor('accent_outline') })

          Text('应用已锁定')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
            .margin({ top: 20 })

          Text(this.modeHint())
            .fontSize(13)
            .fontColor(skinColor('text_muted'))
            .lineHeight(20)
            .margin({ top: 8 })

          Button(this.buttonLabel())
            .width('72%')
            .height(44)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(skinColor('accent_solid'))
            .fontColor(skinColor('accent_contrast'))
            .borderRadius(16)
            .enabled(!this.authenticating)
            .margin({ top: 28 })
            .onClick(() => {
              this.requestUnlock();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)

        Blank()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(skinColor('page_bg'))
    }
  }
}
