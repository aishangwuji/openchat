import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'state/assets_controller.dart';
import 'state/chat_controller.dart';
import 'state/settings_controller.dart';
import 'ui/app_lock_gate.dart';
import 'ui/pages/chat_page.dart';
import 'ui/widgets/update_install_host.dart';

class BalanceApp extends StatelessWidget {
  const BalanceApp({
    super.key,
    required this.settings,
    required this.assets,
    required this.chat,
  });

  final SettingsController settings;
  final AssetsController assets;
  final ChatController chat;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<AssetsController>.value(value: assets),
        ChangeNotifierProvider<ChatController>.value(value: chat),
      ],
      child: const _AppView(),
    );
  }
}

class _AppView extends StatelessWidget {
  const _AppView();

  @override
  Widget build(BuildContext context) {
    final SettingsController settings = context.watch<SettingsController>();
    final Locale locale =
        Locale(settings.language == 'en-US' ? 'en' : 'zh');
    return MaterialApp(
      title: 'openchat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.of(settings.skin.light, Brightness.light),
      darkTheme: AppTheme.of(settings.skin.dark, Brightness.dark),
      themeMode: settings.themeMode,
      locale: locale,
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (BuildContext context, Widget? child) {
        final SettingsController current =
            context.watch<SettingsController>();
        return AppLockGate(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(current.fontScale),
            ),
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: const UpdateInstallHost(child: StartupGate()),
    );
  }
}

/// Loads local chat state before the first frame.
///
/// The model list refresh is intentionally fire-and-forget inside
/// [ChatController.init], so startup is not blocked by the network.
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool _ready = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await context.read<ChatController>().init();
    } catch (error) {
      _error = error;
    }
    if (mounted) {
      setState(() => _ready = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'B',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '启动失败：$_error',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }
    return const ChatPage();
  }
}

