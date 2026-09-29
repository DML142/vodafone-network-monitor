import 'package:flutter/material.dart';

import '../features/charts/charts_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/permissions/permission_diagnostics_screen.dart';
import '../features/sessions/sessions_screen.dart';
import '../features/settings/settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    required this.themeMode,
    required this.onThemeModeChanged,
    super.key,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  static const List<String> _titles = [
    'Обзор',
    'Графики',
    'Сессии',
    'Настройки',
    'Диагностика',
  ];

  @override
  Widget build(BuildContext context) {
    final screens = [
      const DashboardScreen(),
      const ChartsScreen(),
      const SessionsScreen(),
      SettingsScreen(
        themeMode: widget.themeMode,
        onThemeModeChanged: widget.onThemeModeChanged,
      ),
      const PermissionDiagnosticsScreen(),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(_titles[_selectedIndex])),
      body: IndexedStack(index: _selectedIndex, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Обзор',
          ),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Графики'),
          NavigationDestination(icon: Icon(Icons.history), label: 'Сессии'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Настройки'),
          NavigationDestination(
            icon: Icon(Icons.info_outline),
            label: 'Диагностика',
          ),
        ],
      ),
    );
  }
}
