/*
 * AuthService.ets
 *
 * 系统身份认证封装 —— 应用锁与保密会话共用。
 * 应用锁按用户选择收窄为「人脸 / 指纹 / 锁屏密码 / 系统自选」；保密会话仍走系统自选。
 * 遵循 ArkTS 严格模式规范：无 any/unknown，无解构，强类型定义。
 */

import { userAuth } from '@kit.UserAuthenticationKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLockAuthMode } from './SettingsService';

const DOMAIN = 0x0000;
const TAG = 'AuthService';

export class AuthService {
  /** 认证面板是否正在展示；供应用生命周期判断，避免认证期间误触发应用锁。 */
  private static inProgress: boolean = false;

  public static isInProgress(): boolean {
    return AuthService.inProgress;
  }

  /** 解锁方式对应的系统凭据类型（any 不在本函数内处理）。 */
  private static typeForMode(mode: AppLockAuthMode): userAuth.UserAuthType {
    if (mode === 'face') {
      return userAuth.UserAuthType.FACE;
    }
    if (mode === 'fingerprint') {
      return userAuth.UserAuthType.FINGERPRINT;
    }
    return userAuth.UserAuthType.PIN;
  }

  /**
   * 解锁方式对应的凭据类型集合。
   *
   * Business Rule: any（系统自选）必须包含 PIN。系统 UserAuth 组件明确拒绝
   *   「仅人脸+指纹」的组合（真机日志 `CheckAuthWidgetParam: only face+finger not support`，
   *   start 直接返回错误码 8），会导致弹窗不出现、直接判定失败。带上 PIN 后系统弹窗
   *   仍优先引导指纹/人脸，用户可自选。
   */
  private static typesForMode(mode: AppLockAuthMode): userAuth.UserAuthType[] {
    if (mode === 'any') {
      return [
        userAuth.UserAuthType.FACE,
        userAuth.UserAuthType.FINGERPRINT,
        userAuth.UserAuthType.PIN
      ];
    }
    return [AuthService.typeForMode(mode)];
  }

  /**
   * 设备当前是否可用指定解锁方式（凭据已录入且未过期）。
   * Reason: 用户可能先选「仅人脸」再在系统设置里删掉人脸，若锁定后仍强行只调人脸，
   *   会把用户永久挡在应用外；锁定页据此回退到系统自选。
   */
  public static isModeAvailable(mode: AppLockAuthMode): boolean {
    if (mode === 'any') {
      return true;
    }
    try {
      // 无返回值；不可用/未录入时以 BusinessError（12500005/12500010/12500013）抛出。
      userAuth.getAvailableStatus(AuthService.typeForMode(mode), userAuth.AuthTrustLevel.ATL2);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'auth mode %{public}s unavailable, code=%{public}d, message=%{public}s',
        mode, error.code, error.message);
      return false;
    }
  }

  /** 解析实际可用的解锁方式：所选方式不可用时回退 any，避免把用户锁在门外。 */
  public static effectiveMode(mode: AppLockAuthMode): AppLockAuthMode {
    if (mode === 'any' || AuthService.isModeAvailable(mode)) {
      return mode;
    }
    return 'any';
  }

  /**
   * 拉起系统身份认证面板。
   *
   * @param title 认证面板标题。
   * @param mode 解锁方式；默认 any（密码/指纹/人脸由系统弹窗内自选）。
   * @returns 认证是否通过；取消、失败或能力不可用均返回 false。
   */
  public static authenticate(title: string, mode: AppLockAuthMode = 'any'): Promise<boolean> {
    if (AuthService.inProgress) {
      return Promise.resolve(false);
    }

    // 防御：设置页已做可用性校验，但系统凭据可能在选完之后被删除。
    const effective: AppLockAuthMode = AuthService.effectiveMode(mode);
    const authTypes: userAuth.UserAuthType[] = AuthService.typesForMode(effective);

    let challenge: Uint8Array = new Uint8Array(0);
    try {
      // Reason: challenge 用于防重放；本地认证不校验 token，但仍使用系统随机数满足接口语义。
      challenge = cryptoFramework.createRandom().generateRandomSync(16).data;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'generate challenge failed: %{public}s', String(err));
    }

    const authParam: userAuth.AuthParam = {
      challenge: challenge,
      authType: authTypes,
      authTrustLevel: userAuth.AuthTrustLevel.ATL2
    };
    const widgetParam: userAuth.WidgetParam = {
      title: title
    };

    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      let instance: userAuth.UserAuthInstance | undefined = undefined;
      const callback: userAuth.IAuthCallback = {
        onResult: (result: userAuth.UserAuthResult) => {
          AuthService.inProgress = false;
          if (instance !== undefined) {
            try {
              instance.off('result', callback);
            } catch (err) {
              hilog.warn(DOMAIN, TAG, 'off result failed: %{public}s', String(err));
            }
          }
          resolve(result.result === userAuth.UserAuthResultCode.SUCCESS);
        }
      };

      try {
        instance = userAuth.getUserAuthInstance(authParam, widgetParam);
        instance.on('result', callback);
        AuthService.inProgress = true;
        instance.start();
      } catch (err) {
        AuthService.inProgress = false;
        const error: BusinessError = err as BusinessError;
        hilog.error(DOMAIN, TAG, 'start auth failed, mode=%{public}s, code=%{public}d, message=%{public}s',
          effective, error.code, error.message);
        resolve(false);
      }
    });
  }
}
