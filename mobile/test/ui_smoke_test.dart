import 'package:balance_app/app.dart';
import 'package:balance_app/core/theme/app_theme.dart';
import 'package:balance_app/data/services/auth_service.dart';
import 'package:balance_app/data/services/chat_storage_service.dart';
import 'package:balance_app/data/services/key_store.dart';
import 'package:balance_app/data/services/preferences_service.dart';
import 'package:balance_app/state/assets_controller.dart';
import 'package:balance_app/state/chat_controller.dart';
import 'package:balance_app/state/settings_controller.dart';
import 'package:balance_app/ui/pages/assets_page.dart';
import 'package:balance_app/ui/pages/chat_page.dart';
import 'package:balance_app/ui/pages/settings_page.dart';
import 'package:balance_app/data/models/chat_models.dart';
import 'package:balance_app/ui/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef Bootstrapped = ({
  SettingsController settings,
  AssetsController assets,
  ChatController chat,
});

Future<Bootstrapped> bootstrap({
  Map<String, Object> initial = const <String, Object>{},
}) async {
  SharedPreferences.setMockInitialValues(initial);
  final PreferencesService prefs = await PreferencesService.load();
  final KeyStore keyStore = KeyStore();
  final SettingsController settings = await SettingsController.load(
    prefs: prefs,
    keyStore: keyStore,
  );
  final AssetsController assets = AssetsController(
    prefs: prefs,
    keyStore: keyStore,
  );
  final ChatController chat = ChatController(
    storage: ChatStorageService(prefs),
    settings: settings,
    keyStore: keyStore,
    auth: AuthService(),
  );
  return (settings: settings, assets: assets, chat: chat);
}

Future<Widget> buildApp({
  required Widget home,
  Bootstrapped? controllers,
}) async {
  final Bootstrapped boot = controllers ?? await bootstrap();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsController>.value(value: boot.settings),
      ChangeNotifierProvider<AssetsController>.value(value: boot.assets),
      ChangeNotifierProvider<ChatController>.value(value: boot.chat),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: home,
    ),
  );
}

void main() {
  test('chat controller initializes from empty storage', () async {
    final Bootstrapped boot = await bootstrap();
    await boot.chat.init().timeout(const Duration(seconds: 5));
    expect(boot.chat.initialized, true);
    expect(boot.chat.sessions, isEmpty);
  });

  testWidgets('app lock overlay covers the entry when enabled', (
    WidgetTester tester,
  ) async {
    final Bootstrapped boot = await bootstrap(
      initial: <String, Object>{'app_lock_enabled': true},
    );
    await tester.pumpWidget(
      BalanceApp(
        settings: boot.settings,
        assets: boot.assets,
        chat: boot.chat,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('应用已锁定'), findsOneWidget);
  });

  testWidgets('app lock falls back to system dialog without biometrics', (
    WidgetTester tester,
  ) async {
    // The test binding has no local_auth plugin, so "biometrics only" cannot
    // run and the gate must fall back instead of leaving the user locked out.
    final Bootstrapped boot = await bootstrap(
      initial: <String, Object>{
        'app_lock_enabled': true,
        'app_lock_auth_mode': 'biometric',
      },
    );
    await tester.pumpWidget(
      BalanceApp(
        settings: boot.settings,
        assets: boot.assets,
        chat: boot.chat,
      ),
    );
    await tester.pump();
    // Biometric probe has a 1.5s safety timeout when the platform channel is
    // unavailable, so advance past it before asserting the fallback copy.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('所选验证方式不可用，已改用系统验证'), findsOneWidget);
  });

  testWidgets('chat page renders empty state and drawer', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(await buildApp(home: const ChatPage()));
    await tester.pumpAndSettle();
    // 首屏改为「品牌标记 + 时段问候」，不再有固定标语；断言输入卡片与品牌图存在。
    expect(find.text('输入您的问题...'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);

    await tester.tapAt(const Offset(34, 28));
    await tester.pumpAndSettle();
    // 抽屉头部改版后对齐官方：搜索框取代标题行，入口按钮与底部菜单保留。
    expect(find.text('搜索会话内容'), findsOneWidget);
    expect(find.text('+ 新会话'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('settings page renders sections', (WidgetTester tester) async {
    await tester.pumpWidget(await buildApp(home: const SettingsPage()));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('应用'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('资产监控'), findsOneWidget);
  });

  testWidgets('assets page renders empty state', (WidgetTester tester) async {
    await tester.pumpWidget(await buildApp(home: const AssetsPage()));
    await tester.pumpAndSettle();
    expect(find.text('资产监控'), findsOneWidget);
    expect(find.text('暂无服务商'), findsOneWidget);
  });

  testWidgets('assistant markdown bubble renders without exceptions', (
    WidgetTester tester,
  ) async {
    final Bootstrapped boot = await bootstrap();
    final ChatMessage message = ChatMessage(
      id: 'm1',
      role: MessageRole.assistant,
      content: '# 标题\n\n```dart\nprint("hi");\n```\n\n结论[ref_1]。',
      reasoningContent: '先分析问题。',
      createdAt: 0,
      status: MessageStatus.success,
    );
    await tester.pumpWidget(
      await buildApp(
        controllers: boot,
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              message: message,
              controller: boot.chat,
              identityName: '',
              speakerName: '助手',
              onLongPress: () {},
              onBranchChange: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('标题'), findsWidgets);
  });
}
