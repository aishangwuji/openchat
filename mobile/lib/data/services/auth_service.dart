import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// System identity authentication shared by app lock and private sessions.
///
/// Business Rule:
/// 1. `biometricOnly: false` allows the OS to fall back to the device PIN,
///    matching the HarmonyOS behavior where the system dialog chooses the
///    strongest available factor.
/// 2. `biometricOnly: true` (app lock set to "biometrics only") prevents the
///    PIN fallback. The OS still decides whether to use face or fingerprint;
///    the app can only tell the system to use "biometrics" as a class.
/// 3. `persistAcrossBackgrounding` keeps the session alive while the system
///    auth sheet temporarily backgrounds the app.
class AuthService {
  AuthService({LocalAuthentication? authenticator})
      : _auth = authenticator ?? LocalAuthentication();

  final LocalAuthentication _auth;

  static bool _inProgress = false;

  static bool get isInProgress => _inProgress;

  /// Whether biometric-only authentication can actually run on this device.
  ///
  /// Reason: users may pick "biometrics only" and later remove their
  /// fingerprint/face; the lock gate falls back to the full system dialog
  /// instead of leaving them locked out.
  Future<bool> isBiometricAvailable() async {
    try {
      // Reason: the lock overlay must never hang on a stuck platform channel;
      // if the capability probe does not answer, fall back to the system dialog.
      final bool canCheck = await _auth.canCheckBiometrics
          .timeout(const Duration(milliseconds: 1500), onTimeout: () => false);
      if (!canCheck) {
        return false;
      }
      final List<BiometricType> enrolled = await _auth.getAvailableBiometrics().timeout(
            const Duration(milliseconds: 1500),
            onTimeout: () => const <BiometricType>[],
          );
      return enrolled.contains(BiometricType.face) ||
          enrolled.contains(BiometricType.fingerprint) ||
          enrolled.contains(BiometricType.strong) ||
          enrolled.contains(BiometricType.weak);
    } catch (error) {
      debugPrint('AuthService: biometric availability check failed: $error');
      return false;
    }
  }

  Future<bool> authenticate(String reason, {bool biometricOnly = false}) async {
    if (_inProgress) {
      return false;
    }
    bool supported = false;
    try {
      supported = await _auth.isDeviceSupported();
    } catch (error) {
      debugPrint('AuthService: isDeviceSupported failed: $error');
    }
    if (!supported) {
      return false;
    }
    _inProgress = true;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: biometricOnly,
        persistAcrossBackgrounding: true,
      );
    } catch (error) {
      debugPrint('AuthService: authenticate failed: $error');
      return false;
    } finally {
      _inProgress = false;
    }
  }
}
