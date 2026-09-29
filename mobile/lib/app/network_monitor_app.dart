import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/monitoring/network_monitor_controller.dart';
import 'app_shell.dart';
import 'app_theme.dart';

class NetworkMonitorApp extends StatefulWidget {
  const NetworkMonitorApp({super.key});

  @override
  State<NetworkMonitorApp> createState() => _NetworkMonitorAppState();
}

class _NetworkMonitorAppState extends State<NetworkMonitorApp>
    with WidgetsBindingObserver {
  final _monitor = NetworkMonitorController();
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _monitor.setAppForeground(
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    _monitor.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _monitor.setAppForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _monitor.dispose();
    super.dispose();
  }

  void _setThemeMode(ThemeMode themeMode) {
    setState(() => _themeMode = themeMode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Монитор сети',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _themeMode,
      home: AppShell(
        themeMode: _themeMode,
        onThemeModeChanged: _setThemeMode,
        monitor: _monitor,
      ),
    );
  }
}
