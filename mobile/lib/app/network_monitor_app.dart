import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_shell.dart';
import 'app_theme.dart';

class NetworkMonitorApp extends StatefulWidget {
  const NetworkMonitorApp({super.key});

  @override
  State<NetworkMonitorApp> createState() => _NetworkMonitorAppState();
}

class _NetworkMonitorAppState extends State<NetworkMonitorApp> {
  ThemeMode _themeMode = ThemeMode.dark;

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
      home: AppShell(themeMode: _themeMode, onThemeModeChanged: _setThemeMode),
    );
  }
}
