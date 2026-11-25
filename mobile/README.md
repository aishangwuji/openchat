# BalanceApp Mobile (Android / iOS)

Flutter single-codebase port of the HarmonyOS `BalanceApp`. It keeps the same product
surface: API balance dashboard, multi-provider AI chat, settings, app lock and the
Jev topic gate.

## Status

| Area | HarmonyOS | Flutter (this project) |
| --- | --- | --- |
| Balance dashboard (8 providers) | Yes | Yes |
| Add / remove provider, key update | Yes | Yes |
| Streaming chat + reasoning | Yes | Yes |
| Markdown / code / citations | Yes | Yes |
| Session tree (branch / edit / regenerate) | Yes | Yes |
| Draft session (new session each launch) | Yes | Yes |
| Character cards / user identity | Yes | Yes |
| Private sessions + app lock | Yes | Yes |
| Topic gate (Jev System One / Two) | Yes | Yes |
| Settings (appearance / font / language) | Yes | Yes |
| Multi-language coverage | Settings only | Settings only (same as Harmony) |
| Group chat | Offline | Not implemented |
| Release signing | AGC profile | Debug signing only (see techdebt) |

Verified locally:

- `flutter analyze` — no issues
- `flutter test` — 23 tests pass (topic gate segmentation/masking, citation rewrite, balance parsing, provider endpoints, UI smoke, app-lock overlay, markdown bubble)
- `flutter build apk --debug` — produces `build/app/outputs/flutter-apk/app-debug.apk`
- Runtime device/emulator verification is still pending (the local AVD's system image is incomplete;
  no physical Android device was attached).

## Architecture

```
lib/
  main.dart                  bootstrap: preferences, secure store, controllers
  app.dart                   MaterialApp, theme mode, text scaling, startup gate
  core/
    theme/                   semantic color tokens + Material theme
    i18n/                    settings-page dictionary (zh / en)
    utils/                   citation rewriting
  data/
    models/                  provider + chat models, defensive JSON parsing
    registry/                (reserved)
    services/                balance, chat SSE, model list, storage, Jev, auth, key store
  state/                     ChangeNotifier controllers (settings / assets / chat)
  ui/
    app_lock_gate.dart       global lock overlay + lifecycle observer (method from settings)
    pages/                   chat, assets, settings, topic gate, sheets
    widgets/                 message bubble, thinking toggle, confirm dialog, logos
```

Key design decisions:

1. **Data-driven providers.** Adding a Bearer provider is one entry in
   `lib/data/models/provider.dart`; the balance engine stays generic.
2. **Two error channels.** `fetchProviderBalance` returns `success: false` for
   deterministic failures (empty key, 401/403, non-2xx, malformed JSON, business code),
   and throws for transient transport failures so the UI can keep the last good value.
3. **Async isolation.** Balance refreshes use a monotonically increasing session token;
   chat replies use a generation token. Late callbacks from replaced work are dropped.
4. **Streaming.** `ChatService.streamChat` parses `data:` SSE lines, treats `[DONE]`
   as the only completion signal, and appends `content` / `reasoning_content`.
   UI refreshes are coalesced on a 120 ms ticker.
5. **Context gate.** Assistant replies are segmented losslessly, scored once by
   System One, and masked when persisted. Replay projects through the mask; any
   mismatch fails open to the original text.
6. **Secrets.** API keys live in platform secure storage (Android Keystore / iOS
   Keychain). Logs never print raw keys; `maskKey` is the only display helper.

## Provider icons

Provider marks were re-fetched from the official brand sites / app icons and
normalized to 256×256 transparent PNGs (no hotlinking):

- DeepSeek: official whale mark
- Kimi: official K mark with the blue dot
- OpenRouter: official R glyph, black square removed
- SiliconFlow: official purple mark extracted from `logo-new.svg`
- StepFun: official pixel badge, recolored to the provider accent
- Novita: official geometric mark
- Xiaomi MiMo: official `MIMO` wordmark

Trademarks remain the property of their respective owners; these assets are used
only to identify the provider in the dashboard.

## Run

```bash
cd mobile
flutter pub get
flutter run              # attach an Android device/emulator
```

If Flutter engine artifacts cannot be reached directly, use the official mirror:

```bash
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn   # bash
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"   # PowerShell
```

## Build

Android (debug, no signing setup required):

```bash
flutter build apk --debug
```

Android release requires a keystore. Copy `android/key.properties.example` to
`android/key.properties`, fill in the keystore path and passwords, then:

```bash
keytool -genkey -v -keystore balanceapp-release.jks -keyalg RSA \
  -keysize 2048 -validity 10000 -alias balanceapp
flutter build apk --release
flutter build appbundle --release   # for Google Play
```

If `key.properties` is absent, the release build falls back to debug signing so
local `flutter run --release` still works. See
`techdebt/TD-004-mobile-release-readiness.md`.

iOS:

```bash
flutter build ios --release --no-codesign
```

iOS builds require macOS + Xcode; this repository was developed on Windows, so the
iOS target has been configured but not compiled. Required plist entry
`NSFaceIDUsageDescription` is already present. Bundle id: `com.example.balanceapp`.

## Platform notes

- Android `minSdk` is 24 (required by `local_auth`); `MainActivity` extends
  `FlutterFragmentActivity` so device-credential prompts can be hosted.
- Android manifest declares `INTERNET` and labels the app `BalanceApp`.
- iOS deployment target is 13.0; Face ID usage text is localized in Chinese.
- API keys are **not** shared with the HarmonyOS app (different storage backends).
  Users must configure them again on each platform.

## Known gaps

- Release signing / store metadata / screenshots / privacy policy are not prepared.
- Application id is still the placeholder `com.example.balanceapp`; replace it with your
  own reverse-domain id before publishing (and keep Android/iOS in sync).
- iOS has not been compiled on a Mac yet.
- Chat/assets UI strings are Chinese-first; only the Settings page follows the
  language switch (matching the HarmonyOS behavior).
- Session message bodies remain plaintext in local preferences. The private-session
  flag is a UI gate, not encryption (same debt as HarmonyOS `TD-003`).
- No group chat, no file/image upload, no token usage accounting (by design).
